# frozen_string_literal: true

module RmcpDsl
  # Transpiles one `body do |a, b| ... end` block to Rust text.
  # expr() returns [rust, type, atomic]; atomic means "safe as an operand or receiver
  # without parentheses". Types: :i32 :i64 :f64 :bool :string :str (&'static str) :int (literal).
  class Body
    include Diag

    ARITH = %i[+ - * / %].freeze
    ORDER = %i[< <= > >=].freeze
    EQ = %i[== !=].freeze
    INTS = %i[i32 i64].freeze
    NUM = %i[i32 i64 f64 int].freeze
    STRM = { upcase: "to_uppercase", downcase: "to_lowercase" }.freeze
    # Every method a body may call, for the refusal message and the generated skill. The shim
    # catalog (spec/shims/string.yml) documents the string ones; test/test_skill.rb checks the two agree.
    ALLOWED_METHODS = %w[+ - * / % == != < <= > >= ! -@ to_s upcase downcase strip gsub sub split length size
                         capitalize map join start_with? end_with? include? empty? match? reverse first last [] index tr delete
                         squeeze to_i select reject find any? all? count sort uniq partition chars lines times upto downto
                         sum min max to_a fetch key? has_key? member? keys values merge tally].freeze
    # Values that may be nil in Ruby (list indexing, index): Option in Rust. Only `|| default`,
    # `.nil?` and `.to_s` may consume them, so a missing value is never silently used.
    OPT_FIXED = { ostr: :string, oi64: :i64, oi32: :i32, of64: :f64, obool: :bool, ostrs: :strs, oi64s: :i64s }.freeze
    OPT = CompositeTypes::OptTable.new(OPT_FIXED)
    OPT_OF = CompositeTypes::OptOfTable.new(OPT_FIXED.invert) # element type -> nil-able type, for optional fields
    # Typed maps (T::Hash[String, V]); see CompositeTypes. Like a list they are only ever borrowed.
    MAPS = CompositeTypes::MapTable.new
    MAP_ARITY = { :[] => 1, :fetch => 1..2, :key? => 1, :has_key? => 1, :member? => 1, :include? => 1, :keys => 0,
                  :values => 0, :size => 0, :length => 0, :empty? => 0, :merge => 1 }.freeze
    LIST_BLOCK = %i[select reject find any? all? count].freeze
    # List types and their element types. Code that differs between the two lives in list_call and its
    # helpers; everything else treats a list as opaque.
    LISTS = { strs: :string, i64s: :i64 }.freeze
    LIST_OF = LISTS.invert.freeze
    LIST_ARITY = { length: 0, size: 0, empty?: 0, first: 0, last: 0, sort: 0, uniq: 0, reverse: 0, to_a: 0,
                   sum: 0, min: 0, max: 0, join: 0..1, :[] => 1, include?: 1, map: 0, select: 0, reject: 0,
                   find: 0, any?: 0, all?: 0, count: 0, tally: 0 }.freeze
    INT_LIST_METHODS = %i[sum min max].freeze
    LIST_METHODS = (%i[length size map join first last [] empty? include? sort uniq reverse to_a tally] + LIST_BLOCK).freeze
    # One-string-argument tests: Ruby method => Rust str method. Regex arguments are refused (use match?).
    STR_TESTS = { start_with?: "starts_with", end_with?: "ends_with", include?: "contains" }.freeze
    # Ruby split with no argument: ASCII whitespace separators only (no NBSP, no NUL).
    SPLIT_WS = %q(|c: char| matches!(c, ' ' | '\t' | '\n' | '\u{b}' | '\u{c}' | '\r'))
    # Ruby String#strip: NUL, tab, LF, VT, FF, CR and space. Rust trim() differs
    # (Unicode whitespace, no NUL), so the set is spelled out. See spec/shims/string.yml.
    STRIP_FN = %q(|c: char| matches!(c, '\u{0}' | '\t' | '\n' | '\u{b}' | '\u{c}' | '\r' | ' '))

    def initialize(path, params, regexes = [], externs = {}, flags = {}, tool = nil, bindings = {}, helpers = {}, structs = [], outputs = [])
      @path = path
      @outputs = outputs # structured results a tool may build with Name.new(...)
      @structs = structs # every params struct, so a nested object's fields can be read
      @helpers = helpers # helpers declared above this body: name -> record (see Reader#helper_decl)
      @ret = :string     # what `return` must return: a tool returns a string, a helper its declared type
      @helper = false
      @bindings = bindings
      @regexes = regexes
      @externs = externs
      @flags = flags
      @tool = tool
      @fallible = false
      @read = {}       # names of locals / block parameters that are read somewhere
      @declared = []   # [name, node, what] for every local and block parameter declared
      # An optional field is nil-able in the body: use `|| default`, `.nil?` or `.to_s`.
      @types = params["fields"].to_h { |f| [f["name"], field_type(f)] }
    end

    def lower(blk, output = nil)
      names = block_params(blk.parameters)
      @ret = :"struct:#{output}" if output
      env = names.to_h { |n| [n.to_sym, @types.fetch(n)] }
      names.each_with_index do |n, i|
        @declared << [n.to_sym, blk.parameters.parameters.requireds[i], "parameter"]
        note_decl(blk.parameters.parameters.requireds[i].location, n.to_sym, "parameter", env[n.to_sym])
      end
      st = blk.body
      bad(blk, "empty body") unless st
      bad(st, "unsupported #{nodename(st)} as body") unless st.is_a?(Prism::StatementsNode)
      lets, e, t, = stmts(st, env)
      e = unparen(e)
      bad(st, "a body cannot end in `raise` or `return`; end it in a string value") if t == :never
      if output
        bad(st, "this tool returns #{output}; end the body with result(:#{output}, ...), got #{t}") unless t == @ret
      elsif %i[block blocks].include?(t)
        e = "vec![#{e}]" if t == :block
      else
        bad(st, "body must return a string, got #{TypeNames.display(t)}; use .to_s, or end it in a content block such as text(...) or image(...)") unless %i[string str].include?(t)
        e = "#{e}.to_string()" if t == :str
      end
      reject_unused
      type = output ? "struct:#{output}" : (%i[block blocks].include?(t) ? "blocks" : "string")
      { "args" => names, "locals" => lets, "expr" => e, "type" => type, "fallible" => @fallible }
    end

    private

    # Rust would warn about these, so the DSL refuses them: the compiled code stays warning-free
    # and the DSL file says exactly what the implementation does.
    def reject_unused
      name, node, what = @declared.find { |n, _, _| !@read[n] }
      return unless name

      hint = if what == "local" then "remove it, or use it"
             elsif @helper then "remove it from the helper's `args:` and its |...| list"
             else "remove it from the |...| list (callers still send that field)"
             end
      bad(node, "#{what} `#{name}` is never read; #{hint}")
    end

    def block_params(ps)
      return [] unless ps
      bad(ps, "unsupported #{nodename(ps)} as body parameters") unless ps.is_a?(Prism::BlockParametersNode)
      bad(ps, "block-local variables are not allowed") unless ps.locals.empty?
      pn = ps.parameters
      return [] unless pn
      extra = [pn.optionals, pn.posts, pn.keywords].any? { |x| !x.empty? } || pn.rest || pn.keyword_rest || pn.block
      bad(pn, "only plain required parameters are allowed") if extra
      pn.requireds.each_with_object([]) do |r, acc|
        bad(r, "unsupported #{nodename(r)} as a body parameter") unless r.is_a?(Prism::RequiredParameterNode)
        unless @types.key?(r.name.to_s)
          bad(r, "`#{r.name}` is not a field of the tool's params (fields: #{@types.keys.join(', ')})", word: r.name, from: @types.keys)
        end
        bad(r, "duplicate parameter `#{r.name}`") if acc.include?(r.name.to_s)
        acc << r.name.to_s
      end
    end

    # [let-lines, final expr, type, atomic]; only `name = expr` may precede the last expression.
    def stmts(st, env)
      init = st.body[0...-1]
      lets = init.map do |n|
        next guard(n, env) if n.is_a?(Prism::IfNode) || n.is_a?(Prism::UnlessNode)

        bad(n, "unsupported #{nodename(n)} as a statement (only `name = expr` or a guard clause before the last expression)") unless n.is_a?(Prism::LocalVariableWriteNode)
        bad(n, "`#{n.name}` is already defined (no reassignment)") if env.key?(n.name)
        bad(n, "local `#{n.name}` must be snake_case and not a Rust keyword") if !n.name.to_s.match?(SNAKE) || RUST_KW.include?(n.name.to_s)
        e, t, = expr(n.value, env)
        env[n.name] = t
        @declared << [n.name, n, "local"]
        note_decl(n.name_loc, n.name, "local", t)
        "let #{n.name} = #{e};"
      end
      [lets, *expr(st.body.last, env)]
    end

    # The one place every expression is typed; with --types each typed node is also reported.
    def expr(n, env)
      r = expr_node(n, env)
      note_expr(n, r[1]) if @flags["types"]
      r
    end

    # Reports go to the collector only for the DSL file itself (a binding file has its own path).
    def note_type(loc, kind, sym, name = nil)
      c = @flags["types"]
      c.add(loc, kind, TypeNames.display(sym), name: name) if c && c.path == @path
    end

    def note_decl(loc, name, kind, sym)
      (@var_kind ||= {})[name] = kind
      note_type(loc, kind, sym, name)
    end

    def note_expr(n, sym)
      if n.is_a?(Prism::LocalVariableReadNode)
        note_type(n.location, (@var_kind || {}).fetch(n.name, "local"), sym, n.name)
      elsif n.is_a?(Prism::CallNode) && n.name == :result && n.receiver.nil? && sym.to_s.start_with?("struct:")
        note_type(n.location, "output", sym, sym.to_s.delete_prefix("struct:"))
      else
        note_type(n.location, "expression", sym)
      end
    end

    def expr_node(n, env)
      case n
      when Prism::IntegerNode then [n.value.negative? ? "(#{n.value})" : n.value.to_s, :int, true]
      when Prism::FloatNode then [n.value.negative? ? "(#{n.value})" : n.value.to_s, :f64, true]
      when Prism::StringNode then [RmcpDsl.rstr(n.unescaped), :str, true]
      when Prism::TrueNode then ["true", :bool, true]
      when Prism::FalseNode then ["false", :bool, true]
      when Prism::LocalVariableReadNode
        @read[n.name] = true
        [n.name.to_s, env.fetch(n.name) { bad(n, "undefined local `#{n.name}`") }, true]
      when Prism::ParenthesesNode then parens(n, env)
      when Prism::AndNode, Prism::OrNode then logic(n, env)
      when Prism::IfNode then cond(n, env)
      when Prism::UnlessNode then unless_expr(n, env)
      when Prism::CaseNode then case_expr(n, env)
      when Prism::ArrayNode then array_lit(n, env)
      when Prism::HashNode then map_lit(n, env)
      when Prism::RangeNode then range_lit(n, env)
      when Prism::ReturnNode then return_expr(n, env)
      when Prism::InterpolatedStringNode then interp(n, env)
      when Prism::RegularExpressionNode then [regex_id(n), :regex, true]
      when Prism::CallNode then send_expr(n, env)
      else bad(n, "unsupported #{nodename(n)} in body")
      end
    end

    def parens(n, env)
      st = n.body
      bad(n, "parentheses must hold exactly one expression") unless st.is_a?(Prism::StatementsNode) && st.body.size == 1
      e, t, atomic = expr(st.body[0], env)
      [atomic ? e : "(#{e})", t, true]
    end

    def wrap(r) = r[2] ? r[0] : "(#{r[0]})"

    # `(x)` around a whole branch or body is redundant in Rust, and rustc warns (unused_parens).
    # Strips one outer pair only when it encloses the entire expression, ignoring string literals.
    def unparen(code)
      return code unless code.start_with?("(") && code.end_with?(")")

      depth = 0
      in_str = false
      i = 0
      while i < code.length
        ch = code[i]
        if in_str
          i += 1 if ch == "\\"
          in_str = false if ch == "\""
        elsif ch == "\""
          in_str = true
        elsif ch == "("
          depth += 1
        elsif ch == ")"
          depth -= 1
          return code if depth.zero? && i < code.length - 1
        end
        i += 1
      end
      code[1..-2]
    end

    def logic(n, env)
      l = expr(n.left, env)
      # `maybe_list || []`: an empty list of the same kind as the left side.
      if n.is_a?(Prism::OrNode) && OPT.key?(l[1]) && empty_default?(OPT[l[1]], n.right)
        return ["#{wrap(l)}.unwrap_or_default()", OPT.fetch(l[1]), true]
      end

      r = expr(n.right, env)
      return opt_or(n, l, r) if n.is_a?(Prism::OrNode) && OPT.key?(l[1])

      bad(n, "`&&`/`||` need bool operands, got #{l[1]} and #{r[1]}") unless l[1] == :bool && r[1] == :bool
      ["#{wrap(l)} #{n.is_a?(Prism::AndNode) ? '&&' : '||'} #{wrap(r)}", :bool, false]
    end

    def cond(n, env)
      c = expr(n.predicate, env)
      bad(n.predicate, "condition must be bool, got #{c[1]}") unless c[1] == :bool
      sub = n.subsequent
      bad(n, "`if` used as a value needs an `else` branch") unless sub
      tb, tt = branch(n.statements, env, n)
      if sub.is_a?(Prism::IfNode)
        fb, ft, = cond(sub, env)
      elsif sub.is_a?(Prism::ElseNode)
        fb, ft = branch(sub.statements, env, sub)
      else
        bad(sub, "unsupported #{nodename(sub)} in `if`")
      end
      ["if #{c[0]} #{tb} else #{fb}", unify(n, tt, ft), false]
    end

    # A :str branch becomes an owned String so both arms of an `if` have one Rust type.
    def branch(st, env, at)
      bad(at, "empty branch") unless st.is_a?(Prism::StatementsNode)
      lets, e, t, = stmts(st, env.dup)
      e = unparen(e)
      e, t = "#{e}.to_string()", :string if t == :str
      ["{ #{(lets + [e]).join(' ')} }", t]
    end

    def interp(n, env)
      fmt = +""
      vals = []
      n.parts.each do |part|
        case part
        when Prism::StringNode then fmt << RmcpDsl.esc(part.unescaped).gsub("{", "{{").gsub("}", "}}")
        when Prism::EmbeddedStatementsNode
          st = part.statements
          bad(part, "interpolation must hold exactly one expression") unless st && st.body.size == 1
          fmt << "{}"
          v = expr(st.body[0], env)
          bad(part, "this value may be nil; use `|| default` or `.to_s` inside the string") if OPT.key?(v[1])
          bad(part, "a list cannot go inside a string; use join") if LISTS.key?(v[1])
          bad(part, "a map cannot go inside a string; read one value with m[\"key\"] (or join its keys)") if MAPS.key?(v[1])
          bad(part, "#{opaque_name(v[1])} is an opaque value; pass it to a function of its binding to get a string out") if opaque?(v[1])
          bad(part, "an object cannot go inside a string; read one of its fields") if v[1].to_s.start_with?("struct:")
          bad(part, "a content block cannot go inside a string; return it from the body") if %i[block blocks].include?(v[1])
          vals << v[0]
        else bad(part, "unsupported #{nodename(part)} in string")
        end
      end
      ["format!(\"#{fmt}\"#{vals.map { |v| ", #{v}" }.join})", :string, true]
    end

    def send_expr(n, env)
      args = n.arguments ? n.arguments.arguments : []
      name = n.name
      if n.block && name != :map && !LIST_BLOCK.include?(name) && !%i[gsub sub].include?(name)
        bad(n, "blocks are only supported on map, gsub, sub, #{LIST_BLOCK.join(', ')}", word: name, from: %i[map gsub sub] + LIST_BLOCK)
      end
      bad(n, "safe navigation (&.) is not allowed in body expressions") if n.safe_navigation?
      return rust_int(n, args, env) if n.receiver.is_a?(Prism::ConstantReadNode) && n.receiver.name == :Rust
      if n.receiver.is_a?(Prism::ConstantReadNode)
        return binding_call(n, args, env) if @bindings.key?(n.receiver.name.to_s)

        bad(n.receiver, "unknown constant `#{n.receiver.name}`; bindings are loaded with use_bindings :name#{@bindings.empty? ? '' : " (loaded: #{@bindings.keys.join(', ')})"}",
            word: n.receiver.name, from: @bindings.keys + ["Rust"])
      end
      return rust_call(n, args, env) if name == :rust && n.receiver.nil?
      return raise_call(n, args, env) if name == :raise && n.receiver.nil?
      return output_new(n, args, env) if name == :result && n.receiver.nil?

      return integer_call(n, args, env) if name == :Integer && n.receiver.nil?

      return helper_call(n, args, env) if n.receiver.nil? && @helpers.key?(name.to_s)
      return content_call(n, args, env) if n.receiver.nil? && CONTENT_SHAPE.key?(name)

      unless n.receiver
        bad(n, "unsupported call `#{name}` (needs a receiver); a helper can only be called after it is declared, and only from a tool or a later helper" \
               "#{@helpers.empty? ? '' : " (declared helpers: #{@helpers.keys.join(', ')})"}", word: name, from: @helpers.keys)
      end
      bad(n, "`=~` is not supported; use match? for a true or false answer") if name == :=~
      recv = expr(n.receiver, env)
      return struct_field(n, name, recv) if recv[1].to_s.start_with?("struct:") && args.empty?

      if recv[1] == :regex && !%i[gsub sub].include?(name)
        bad(n, "a regex literal can only be the first argument of gsub/sub")
      end
      if OPT.key?(recv[1]) && !(LISTS.key?(OPT[recv[1]]) || MAPS.key?(OPT[recv[1]]) || opaque?(OPT[recv[1]]) ? %i[nil?] : %i[nil? to_s]).include?(name)
        bad(n, "this value may be nil; use `|| default`, `.nil?` or `.to_s` (not `#{name}`)")
      end
      bad(n, "#{opaque_name(recv[1])} is an opaque value with no methods of its own (not `#{name}`); pass it to a function of its binding") if opaque?(recv[1])
      return list_call(n, name, args, recv, env) if LISTS.key?(recv[1])
      return map_call(n, name, args, recv, env) if MAPS.key?(recv[1])

      if (ARITH + ORDER + EQ).include?(name) && args.size == 1
        binop(n, name, recv, expr(args[0], env))
      elsif OPT.key?(recv[1]) && name == :to_s && args.empty?
        opt_to_s(recv)
      elsif OPT.key?(recv[1]) && name == :nil? && args.empty?
        ["#{wrap(recv)}.is_none()", :bool, true]
      elsif name == :to_s && args.empty?
        ["#{wrap(recv)}.to_string()", :string, true]
      elsif STRM.key?(name) && args.empty? && %i[str string].include?(recv[1])
        ["#{wrap(recv)}.#{STRM[name]}()", :string, true]
      elsif name == :split && args.empty? && %i[str string].include?(recv[1])
        ["#{wrap(recv)}.split(#{SPLIT_WS}).filter(|w| !w.is_empty()).collect::<Vec<&str>>()", :strs, true]
      elsif %i[length size].include?(name) && args.empty? && %i[str string].include?(recv[1])
        ["(#{wrap(recv)}.chars().count() as i64)", :i64, true]
      elsif name == :capitalize && args.empty? && %i[str string].include?(recv[1])
        note_capitalize(n)
        # A bare block expression: not atomic, so `wrap` parenthesizes it only when it is a receiver.
        ["{ let mut cs = #{wrap(recv)}.chars(); match cs.next() { Some(f) => f.to_uppercase().collect::<String>() + &cs.as_str().to_lowercase(), None => String::new() } }", :string, false]
      elsif name == :strip && args.empty? && %i[str string].include?(recv[1])
        note_strip(n)
        ["#{wrap(recv)}.trim_matches(#{STRIP_FN}).to_string()", :string, true]
      elsif STR_TESTS.key?(name) && args.size == 1 && %i[str string].include?(recv[1])
        str_test(name, recv, args[0], env)
      elsif name == :empty? && args.empty? && %i[str string].include?(recv[1])
        ["#{wrap(recv)}.is_empty()", :bool, true]
      elsif name == :match? && args.size == 1 && %i[str string].include?(recv[1])
        match_test(recv, args[0])
      elsif name == :reverse && args.empty? && %i[str string].include?(recv[1])
        # Both Ruby and Rust reverse by code point, not by grapheme cluster.
        ["#{wrap(recv)}.chars().rev().collect::<String>()", :string, true]
      elsif name == :split && args.size == 1 && %i[str string].include?(recv[1])
        split_sep(recv, args[0])
      elsif name == :index && args.size == 1 && %i[str string].include?(recv[1])
        str_index(recv, args[0], env)
      elsif name == :tr && args.size == 2 && %i[str string].include?(recv[1])
        str_tr(n, recv, args)
      elsif name == :delete && args.size == 1 && %i[str string].include?(recv[1])
        str_delete(recv, args[0])
      elsif name == :squeeze && args.empty? && %i[str string].include?(recv[1])
        squeeze_code(recv)
      elsif name == :to_i && args.empty? && %i[str string].include?(recv[1])
        str_to_i(n, recv)
      elsif name == :split && args.size == 2 && %i[str string].include?(recv[1])
        split_limit(recv, args)
      elsif name == :partition && args.size == 1 && %i[str string].include?(recv[1])
        str_partition(recv, args[0])
      elsif name == :chars && args.empty? && %i[str string].include?(recv[1])
        ["#{wrap(recv)}.chars().map(|__c| __c.to_string()).collect::<Vec<String>>()", :strs, true]
      elsif name == :lines && args.empty? && %i[str string].include?(recv[1])
        ["#{wrap(recv)}.split_inclusive('\\n').map(|__l| __l.to_string()).collect::<Vec<String>>()", :strs, true]
      elsif name == :[] && args.size.between?(1, 2) && %i[str string].include?(recv[1])
        str_slice(recv, args, env)
      elsif name == :times && args.empty? && %i[int i32 i64].include?(recv[1])
        ["(0..#{wrap(recv)} as i64).collect::<Vec<i64>>()", :i64s, true]
      elsif %i[upto downto].include?(name) && args.size == 1 && %i[int i32 i64].include?(recv[1])
        int_run(name, recv, args[0], env)
      elsif %i[gsub sub].include?(name)
        subst(n, name, recv, args, env)
      elsif name == :! && args.empty? && recv[1] == :bool
        ["!#{wrap(recv)}", :bool, false]
      elsif name == :-@ && args.empty? && (INTS.include?(recv[1]) || RINT.key?(recv[1]))
        checked_neg(n, recv)
      elsif name == :-@ && args.empty? && NUM.include?(recv[1])
        ["-#{wrap(recv)}", recv[1], false]
      else
        bad(n, "unsupported method `#{name}` in body (allowed: #{ALLOWED_METHODS.join(' ')}, or rust(:fn, ...))", word: name, from: ALLOWED_METHODS)
      end
    end

    # `unless c ... else ... end` is `if c ... else ... end` with the branches swapped. As a value
    # it needs the else branch, like `if`.
    def unless_expr(n, env)
      c = expr(n.predicate, env)
      bad(n.predicate, "condition must be bool, got #{c[1]}") unless c[1] == :bool
      els = n.else_clause
      bad(n, "`unless` used as a value needs an `else` branch") unless els
      ub, ut = branch(n.statements, env, n)
      eb, et = branch(els.statements, env, els)
      ["if #{c[0]} #{eb} else #{ub}", unify(n, ut, et), false]
    end

    # `raise "message"` ends the tool call with an MCP error result (isError: true) that carries
    # the message. It has no value, so it fits wherever any type does: `cond ? raise("x") : v`.
    def raise_call(node, args, env)
      bad(node, "`raise` takes exactly one message argument; write `raise \"message\"`") unless args.size == 1
      msg = expr(args[0], env)
      bad(args[0], "`raise` needs a string message, got #{msg[1]}") unless %i[str string].include?(msg[1])
      @fallible = true
      ["return Err(#{msg[1] == :str ? "#{msg[0]}.to_string()" : msg[0]})", :never, false]
    end

    # start_with? / end_with? / include? with one string argument. Ruby takes a regex too for
    # start_with? and include? (a different method); that form is refused here, use match?.
    def str_test(name, recv, arg, env)
      bad(arg, "`#{name}` takes a string, not a regex (use match?)") if arg.is_a?(Prism::RegularExpressionNode)
      a = expr(arg, env)
      bad(arg, "`#{name}` takes a string, got #{a[1]}") unless %i[str string].include?(a[1])
      pat = a[1] == :str ? a[0] : "&#{wrap(a)}"
      ["#{wrap(recv)}.#{STR_TESTS.fetch(name)}(#{pat})", :bool, true]
    end

    # match? with a regex literal: an unanchored search, like Ruby; ^ and $ are line anchors.
    def match_test(recv, pat)
      bad(pat, "`match?` needs a regex literal, got #{nodename(pat)}") unless pat.is_a?(Prism::RegularExpressionNode)
      ["#{regex_id(pat)}.is_match(&#{wrap(recv)})", :bool, true]
    end

    # `maybe || default` for a value that may be nil. The default is only evaluated when the left
    # side is nil, as in Ruby; `xs.first || raise("empty")` ends the call with an error result.
    def opt_or(node, l, r)
      return ["match #{l[0]} { Some(__v) => __v, None => #{r[0]} }", OPT.fetch(l[1]), false] if r[1] == :never

      # A literal default can be evaluated eagerly. Anything else is only evaluated when the left side is nil,
      # as in Ruby, and may contain `return`, `raise` or checked arithmetic, so it goes in a match arm (a
      # closure would swallow the early exit).
      pure = [Prism::StringNode, Prism::IntegerNode, Prism::FloatNode, Prism::TrueNode, Prism::FalseNode].any? { |k| node.right.is_a?(k) }
      lazy = ->(code, type) { ["match #{l[0]} { Some(__v) => __v, None => #{unparen(code)} }", type, false] }

      if LISTS.key?(OPT.fetch(l[1]))
        bad(node.right, "the default for a nil-able list must be a list of the same kind, got #{r[1]}") unless r[1] == OPT.fetch(l[1])
        return lazy.call(r[0], OPT.fetch(l[1]))
      end
      if MAPS.key?(OPT.fetch(l[1]))
        bad(node.right, "the default for a nil-able map must be a map of the same kind, got #{TypeNames.display(r[1])}") unless [OPT.fetch(l[1]), :empty_map].include?(r[1])
        return lazy.call(r[0], OPT.fetch(l[1]))
      end
      if opaque?(OPT.fetch(l[1]))
        bad(node.right, "the default for a nil-able #{opaque_name(OPT.fetch(l[1]))} must be another #{opaque_name(OPT.fetch(l[1]))} (or `raise(\"...\")`), got #{TypeNames.display(r[1])}") unless r[1] == OPT.fetch(l[1])
        return lazy.call(r[0], OPT.fetch(l[1]))
      end

      if l[1] == :ostr
        bad(node.right, "the default for a nil-able string must be a string, got #{r[1]}") unless %i[str string].include?(r[1])
        d = r[1] == :str ? "#{r[0]}.to_string()" : r[0]
        pure ? ["#{wrap(l)}.unwrap_or_else(|| #{d})", :string, true] : lazy.call(d, :string)
      else
        want = OPT.fetch(l[1])
        ok = case want
             when :bool then r[1] == :bool
             when :f64 then %i[f64 int].include?(r[1])
             else r[1] == :int || r[1] == want
             end
        bad(node.right, "the default for a nil-able #{want} must be a #{want}, got #{r[1]}") unless ok
        d = want == :f64 && r[1] == :int ? "#{r[0]} as f64" : r[0]
        pure ? ["#{wrap(l)}.unwrap_or(#{d})", want, true] : lazy.call(d, want)
      end
    end

    # nil.to_s is "" in Ruby.
    def opt_to_s(recv)
      code = if recv[1] == :ostr
               "#{wrap(recv)}.unwrap_or_default()"
             else
               "#{wrap(recv)}.map(|__n| __n.to_string()).unwrap_or_default()"
             end
      [code, :string, true]
    end

    # split("sep"): Ruby keeps leading empty pieces and drops trailing ones. " " (awk mode, any
    # whitespace) and "" (every character) mean something else in Ruby, so they are refused.
    def split_sep(recv, sep)
      bad(sep, "`split` takes a plain string literal separator") unless sep.is_a?(Prism::StringNode)
      bad(sep, "split(\" \") means whitespace in Ruby; use split with no argument") if sep.unescaped == " "
      bad(sep, "split with an empty separator is not supported") if sep.unescaped.empty?
      ["{ let mut __v: Vec<String> = #{wrap(recv)}.split(#{RmcpDsl.rstr(sep.unescaped)}).map(|__p| __p.to_string()).collect(); " \
       "while __v.last().is_some_and(|__l| __l.is_empty()) { __v.pop(); } __v }", :strs, false]
    end

    # index("x"): the character offset of the first match, or nil. Ruby counts characters.
    def str_index(recv, arg, env)
      bad(arg, "`index` takes a string, not a regex") if arg.is_a?(Prism::RegularExpressionNode)
      a = expr(arg, env)
      bad(arg, "`index` takes a string, got #{a[1]}") unless %i[str string].include?(a[1])
      pat = a[1] == :str ? a[0] : "&#{wrap(a)}"
      ["{ let __s = &#{wrap(recv)}; __s.find(#{pat}).map(|__b| __s[..__b].chars().count() as i64) }", :oi64, false]
    end

    # tr and delete take Ruby character sets; only plain characters are supported (no a-z ranges,
    # no ^ negation, no backslashes), so what the DSL says is exactly what the Rust does.
    def plain_chars(node, name)
      bad(node, "`#{name}` takes string literals") unless node.is_a?(Prism::StringNode)
      chars = node.unescaped.chars
      bad(node, "`#{name}` needs at least one character") if chars.empty?
      # A `-` at either end of the set is a literal dash in Ruby; in the middle it makes a range.
      range = chars.each_with_index.any? { |c, i| c == "-" && i.positive? && i < chars.size - 1 }
      if range || chars.any? { |c| ["^", "\\"].include?(c) }
        bad(node, "`#{name}` with ranges (a-z), `^` or backslashes is not supported; list the characters " \
                  "(a `-` at the start or end of the set is fine)")
      end
      chars
    end

    def str_tr(node, recv, args)
      from = plain_chars(args[0], :tr)
      to = plain_chars(args[1], :tr)
      bad(node, "`tr` needs the same number of characters on both sides") unless from.size == to.size
      bad(args[0], "`tr` source characters must be distinct") unless from.uniq.size == from.size
      arms = from.zip(to).map { |a, b| "#{RmcpDsl.rchar(a)} => #{RmcpDsl.rchar(b)}," }.join(" ")
      ["#{wrap(recv)}.chars().map(|__c| match __c { #{arms} _ => __c }).collect::<String>()", :string, true]
    end

    def str_delete(recv, arg)
      set = plain_chars(arg, :delete).map { |c| RmcpDsl.rchar(c) }.join(" | ")
      ["#{wrap(recv)}.chars().filter(|__c| !matches!(*__c, #{set})).collect::<String>()", :string, true]
    end

    # squeeze with no argument collapses every run of the same character.
    def squeeze_code(recv)
      ["{ let mut __o = String::new(); let mut __l: Option<char> = None; for __c in #{wrap(recv)}.chars() { " \
       "if __l != Some(__c) { __o.push(__c); } __l = Some(__c); } __o }", :string, false]
    end

    # case x when "a", "b" then ... when /re/ then ... else ... end. The subject is evaluated once.
    def case_expr(node, env)
      bad(node, "`case` needs a subject: case x when ...") unless node.predicate
      bad(node, "`case` used as a value needs an `else` branch") unless node.else_clause
      subj = expr(node.predicate, env)
      kind = if %i[str string].include?(subj[1]) then :text
             elsif %i[int i32 i64].include?(subj[1]) then :int
             end
      bad(node.predicate, "`case` subject must be a string or an integer, got #{subj[1]}") unless kind
      arms = node.conditions.map do |w|
        bad(w, "unsupported #{nodename(w)} in `case`") unless w.is_a?(Prism::WhenNode)
        body, type = branch(w.statements, env, w)
        [w.conditions.map { |c| when_test(c, kind) }.join(" || "), body, type]
      end
      eb, et = branch(node.else_clause.statements, env, node.else_clause)
      type = arms.reduce(et) { |acc, (_, _, t)| unify(node, acc, t) }
      chain = arms.map { |test, body, _| "if #{test} #{body}" }.join(" else ")
      ["{ let __k = &#{wrap(subj)}; #{chain} else #{eb} }", type, false]
    end

    def when_test(cond, kind)
      case cond
      when Prism::StringNode
        bad(cond, "this `case` compares integers, but `when` has a string") unless kind == :text
        "*__k == #{RmcpDsl.rstr(cond.unescaped)}"
      when Prism::IntegerNode
        bad(cond, "this `case` compares strings, but `when` has an integer") unless kind == :int
        "*__k == #{cond.value.negative? ? "(#{cond.value})" : cond.value}"
      when Prism::RegularExpressionNode
        bad(cond, "a regex `when` needs a string subject") unless kind == :text
        "#{regex_id(cond)}.is_match(__k)"
      else bad(cond, "`when` takes string, integer or regex literals, got #{nodename(cond)}")
      end
    end

    # `return value` ends the tool call with that string. It has no value of its own, so like `raise` it
    # fits wherever any type does (`cond ? (return "x") : y`). It returns from the whole tool, even from
    # inside a list block. A body cannot end in `return`: end it in the value itself.
    def return_expr(node, env)
      args = node.arguments ? node.arguments.arguments : []
      bad(node, "`return` needs exactly one string value") unless args.size == 1
      v = expr(args[0], env)
      code = coerce(v[0], v[1], @ret) or bad(args[0], "`return` needs a #{@ret == :string ? "string" : @ret} value, got #{v[1]}")
      @fallible = true
      ["return Ok(#{code})", :never, false]
    end

    # A guard clause before the last expression: `return "x" if cond`, `raise "msg" unless cond`, or the
    # block form without an else. Anything else as a statement is refused.
    def guard(node, env)
      other = node.is_a?(Prism::IfNode) ? node.subsequent : node.else_clause
      bad(node, "only a guard clause is allowed as a statement: `return x if cond` or `raise \"msg\" if cond` (no else)") if other
      c = expr(node.predicate, env)
      bad(node.predicate, "condition must be bool, got #{c[1]}") unless c[1] == :bool
      st = node.statements
      bad(node, "a guard clause needs a body") unless st.is_a?(Prism::StatementsNode) && st.body.size == 1
      e, t, = expr(st.body[0], env)
      bad(st.body[0], "a guard clause must end with `return` or `raise`") unless t == :never
      test = node.is_a?(Prism::UnlessNode) ? "!#{wrap(c)}" : c[0]
      "if #{test} { #{e}; }"
    end

    # Code for a value of `type` where `want` is expected, or nil when it does not fit. A string literal
    # fits a string, an integer literal an integer type, and a plain value fits its nil-able type (as Some).
    def coerce(code, type, want)
      return code if type == want
      return "#{code}.to_string()" if type == :str && want == :string
      return code if type == :int && %i[i32 i64].include?(want)
      return code if type == :empty_map && MAPS.key?(want)

      if OPT.key?(want)
        inner = coerce(code, type, OPT.fetch(want))
        return "Some(#{inner})" if inner
      end
      nil
    end

    # result(:Name, field: value, ...) builds a tool's structured result. Every field is given exactly once and
    # each value has to fit its field's type, so a result can never be missing or mistyped.
    def output_new(n, args, env)
      bad(n, "result(:Name, field: value, ...) starts with the output's name") unless args[0].is_a?(Prism::SymbolNode)
      sname = args[0].unescaped
      st = @outputs.find { |o| o["name"] == sname } or
        bad(args[0], "unknown output `#{sname}`; declare it with `output :#{sname} do ... end`" \
                     "#{@outputs.empty? ? '' : " (declared outputs: #{@outputs.map { |o| o['name'] }.join(', ')})"}", word: sname, from: @outputs.map { |o| o["name"] })
      names = st["fields"].map { |f| f["name"] }
      kw = args.size == 2 && args[1].is_a?(Prism::KeywordHashNode) ? args[1].elements : nil
      bad(n, "result(:#{sname}, ...) takes one keyword argument for each field: #{names.join(', ')}") unless kw
      given = {}
      kw.each do |el|
        bad(el, "unsupported #{nodename(el)} in result(:#{sname}, ...) (use `field: value`)") unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
        key = el.key.unescaped
        bad(el, "#{sname} has no field `#{key}` (it has: #{names.join(', ')})", word: key, from: names) unless names.include?(key)
        bad(el, "duplicate `#{key}:`") if given.key?(key)
        given[key] = el.value
      end
      missing = names - given.keys
      bad(n, "result(:#{sname}) is missing #{missing.map { |x| "`#{x}:`" }.join(', ')}") unless missing.empty?
      parts = st["fields"].map do |f|
        node = given.fetch(f["name"])
        code, type, = expr(node, env)
        want = field_type(f)
        fits = coerce(code, type, want) or
          bad(node, "`#{f['name']}:` of #{sname} needs #{want == :string ? 'a string' : want}, got #{type}")
        # a local or parameter is read again later, so the struct takes a copy
        fits = "#{fits}.clone()" if node.is_a?(Prism::LocalVariableReadNode) && (%i[string strs i64s].include?(want) || MAPS.key?(want))
        "#{f['name']}: #{fits}"
      end
      ["#{sname} { #{parts.join(', ')} }", :"struct:#{sname}", true]
    end

    # The type a field has inside a body. Lists are lists of strings or integers, a nested object is a
    # struct value (read with `obj.field`), and an optional field is nil-able. A field with a default is
    # always present, so it is not.
    def field_type(f)
      TypeNames.field_symbol(f)
    end

    # obj.name for a nested object field. Strings and lists are cloned so the object can be read again.
    def struct_field(node, name, recv)
      sname = recv[1].to_s.delete_prefix("struct:")
      st = (@structs + @outputs).find { |p| p["name"] == sname } or bad(node, "unknown params `#{sname}`")
      f = st["fields"].find { |x| x["name"] == name.to_s } or
        bad(node, "#{sname} has no field `#{name}` (it has: #{st['fields'].map { |x| x['name'] }.join(', ')})", word: name, from: st["fields"].map { |x| x["name"] })
      type = field_type(f)
      copy = %i[i32 i64 f64 bool oi32 oi64 of64 obool].include?(type)
      ["#{wrap(recv)}.#{name}#{copy ? '' : '.clone()'}", type, true]
    end

    # A helper body: its parameters have the declared types and its last expression must fit the declared
    # result. `return` and `raise` inside it leave the helper, and the caller sees an error result.
    def lower_helper(blk, names, types, ret)
      @ret = ret
      @helper = true
      env = names.zip(types).to_h { |n, t| [n.to_sym, t] }
      reqs = blk.parameters&.parameters&.requireds || []
      names.each_with_index do |n, i|
        @declared << [n.to_sym, reqs[i], "parameter"]
        note_decl(reqs[i].location, n.to_sym, "parameter", env[n.to_sym])
      end
      st = blk.body
      bad(blk, "empty helper body") unless st.is_a?(Prism::StatementsNode)
      lets, e, t, = stmts(st, env)
      bad(st, "a helper cannot end in `raise` or `return`; end it in a value") if t == :never
      code = coerce(unparen(e), t, ret) or bad(st, "the helper returns #{ret} but its body ends in #{t}")
      reject_unused
      { "locals" => lets, "expr" => code, "fallible" => @fallible }
    end
    public :lower_helper

    # name(args) for a declared helper. Arguments are passed owned (strings and lists are cloned, so the
    # caller can keep using them). A helper that can fail returns a Result: the call propagates it with `?`.
    def helper_call(node, args, env)
      h = @helpers.fetch(node.name.to_s)
      unless args.size == h["args"].size
        bad(node, "helper `#{h['name']}` takes #{h['args'].size} argument(s), got #{args.size}; expected `#{h['name']}(#{h['args'].join(', ')})`")
      end
      parts = args.zip(h["args"]).map do |arg, (pname, ptype)|
        r = expr(arg, env)
        want = ptype.to_sym
        code = coerce(wrap(r), r[1], want) or bad(arg, "helper `#{h['name']}`: argument `#{pname}` should be #{want}, got #{r[1]}")
        %i[string strs i64s].include?(want) && r[1] != :str ? "#{code}.clone()" : code
      end
      (@flags["used_helpers"] ||= {})[h["name"]] = true
      call = "helper_#{h['name']}(#{parts.join(', ')})"
      return [call, h["returns"].to_sym, true] unless h["body"]["fallible"]

      @fallible = true
      ["#{call}?", h["returns"].to_sym, true]
    end

    def binop(n, op, l, r)
      if EQ.include?(op) || ORDER.include?(op)
        t = unify(n, norm(l[1]), norm(r[1]))
        bad(n, "`#{op}` needs numeric operands, got #{t}") if ORDER.include?(op) && !NUM.include?(t)
        return ["#{wrap(l)} #{op} #{wrap(r)}", :bool, false]
      end
      return str_repeat(n, l, r) if op == :* && %i[str string].include?(l[1]) && %i[int i32 i64].include?(r[1])

      if op == :+ && l[1] == :string && %i[str string].include?(r[1])
        return ["format!(\"{}{}\", #{l[0]}, #{r[0]})", :string, true]
      end
      rust = RINT.key?(l[1]) || RINT.key?(r[1])
      t = unify(n, RINT.fetch(l[1], l[1]), RINT.fetch(r[1], r[1]))
      bad(n, "`#{op}` needs numeric operands, got #{t}") unless NUM.include?(t)
      return checked_op(n, op, l, r, t, rust) if INTS.include?(t)

      ["#{wrap(l)} #{op} #{wrap(r)}", t, false]
    end

    # The single plain parameter of a list block, checked like a local.
    def block_param(blk, env, what, type)
      ps = blk.parameters
      one = ps.is_a?(Prism::BlockParametersNode) && ps.locals.empty? && ps.parameters
      one &&= ps.parameters.requireds.size == 1 && ps.parameters.requireds[0].is_a?(Prism::RequiredParameterNode)
      one &&= [ps.parameters.optionals, ps.parameters.posts, ps.parameters.keywords].all?(&:empty?)
      one &&= !ps.parameters.rest && !ps.parameters.keyword_rest && !ps.parameters.block
      bad(blk, "#{what} takes a block with exactly one plain parameter") unless one
      name = ps.parameters.requireds[0].name
      bad(blk, "`#{name}` is already defined") if env.key?(name)
      @declared << [name, ps.parameters.requireds[0], "block parameter"]
      note_decl(ps.parameters.requireds[0].location, name, "parameter", type)
      if !name.to_s.match?(SNAKE) || RUST_KW.include?(name.to_s)
        bad(blk, "block parameter `#{name}` must be snake_case and not a Rust keyword")
      end
      name
    end

    # Methods on a list of strings (:strs) or integers (:i64s). Block methods compile to for loops, not
    # closures, so a block may use checked arithmetic, to_i and raise: they leave the enclosing closure
    # with `?` or `return Err`. A list is only ever borrowed, so a local list can be used again.
    def list_call(node, name, args, recv, env)
      elem = LISTS.fetch(recv[1])
      allowed = LIST_METHODS + (elem == :i64 ? INT_LIST_METHODS : [])
      unless allowed.include?(name)
        bad(node, "a list of #{elem == :i64 ? 'integers' : 'strings'} only supports #{allowed.join('/')} so far, not `#{name}`",
            word: name.to_s, from: allowed.map(&:to_s))
      end
      want = LIST_ARITY.fetch(name)
      unless want === args.size
        shape = want.is_a?(Range) ? ".#{name} or .#{name}(arg)" : (want.zero? ? ".#{name}" : ".#{name}(arg)")
        bad(node, "`#{name}` takes #{want.is_a?(Range) ? 'at most one argument' : "#{want} argument(s)"}; write `#{shape}`")
      end

      case name
      when :length, :size then ["(#{wrap(recv)}.len() as i64)", :i64, true]
      when :empty? then ["#{wrap(recv)}.is_empty()", :bool, true]
      when :to_a then recv
      when :first, :last then list_end(name, recv, elem)
      when :[] then list_at(recv, args[0], env, elem)
      when :include? then list_include(recv, args[0], env, elem)
      when :join then join_list(recv, args, elem)
      when :tally then list_tally(node, recv, elem)
      when :sort, :uniq, :reverse then list_reorder(name, recv, elem)
      when :sum then list_sum(node, recv)
      when :min, :max then ["#{wrap(recv)}.iter().copied().#{name}()", :oi64, true]
      else list_block(node, name, recv, env, elem)
      end
    end

    # xs.tally: how many times each string occurs, as a map from string to integer (keys come back sorted).
    def list_tally(node, recv, elem)
      bad(node, "`tally` needs a list of strings, because map keys are strings") unless elem == :string
      ["{ let mut __m = std::collections::BTreeMap::<String, i64>::new(); for __x in #{wrap(recv)}.iter() { " \
       "*__m.entry(__x.to_string()).or_insert(0) += 1; } __m }", CompositeTypes.map_symbol(:i64), false]
    end

    # `maybe || []` and `maybe || {}`: an empty collection of the same kind as the left side, so no default has to be built.
    def empty_default?(inner, node)
      (LISTS.key?(inner) && node.is_a?(Prism::ArrayNode) && node.elements.empty?) ||
        (MAPS.key?(inner) && node.is_a?(Prism::HashNode) && node.elements.empty?)
    end

    # { "a" => 1, "b" => 2 }: a map with String keys and values of one type (String, Integer, Float, true/false, or a list
    # of strings or integers). It is a Rust BTreeMap, so keys come back sorted. `{}` has no type of its own and fits
    # wherever a map is expected.
    def map_lit(n, env)
      return ["std::collections::BTreeMap::new()", :empty_map, true] if n.elements.empty?

      seen = {}
      pairs = n.elements.map do |el|
        bad(el, "a map literal is `\"key\" => value` pairs; `**` and splats are not supported") unless el.is_a?(Prism::AssocNode)
        key = el.key
        if key.is_a?(Prism::SymbolNode)
          bad(key, "map keys are strings: write \"#{key.unescaped}\" => value (a symbol is a different key in Ruby, and these maps have string keys)")
        end
        bad(key, "a map key must be a string literal such as \"name\"") unless key.is_a?(Prism::StringNode)
        bad(key, "duplicate map key \"#{key.unescaped}\"") if seen[key.unescaped]
        seen[key.unescaped] = true
        v = expr(el.value, env)
        bad(el.value, "a map value cannot be nil; use `|| default`") if OPT.key?(v[1])
        [key.unescaped, v, el.value]
      end
      value = map_value_type(n, pairs.map { |_, v, _| v[1] })
      items = pairs.map do |k, v, vnode|
        code = v[1] == :str ? "#{v[0]}.to_string()" : v[0]
        code = "(#{code} as i64)" if v[1] == :i32
        code = "#{wrap(v)}.iter().map(|__s| __s.to_string()).collect::<Vec<String>>()" if value == :strs # owned, whatever the list holds
        code = "#{code}.clone()" if vnode.is_a?(Prism::LocalVariableReadNode) && %i[string i64s].include?(value)
        "(#{RmcpDsl.rstr(k)}.to_string(), #{code})"
      end
      [CompositeTypes.map_rust(value).then { |t| "#{t.sub('<String', '::<String')}::from([#{items.join(', ')}])" },
       CompositeTypes.map_symbol(value), true]
    end

    # The one value type of a literal's values; mixed or unsupported types are refused with what to do instead.
    def map_value_type(node, types)
      kinds = types.map { |t| { str: :string, int: :i64, i32: :i64 }.fetch(t, t) }.uniq
      shown = types.map { |t| TypeNames.display(t) }.uniq
      if kinds.size > 1
        bad(node, "a map holds values of one type, got #{shown.join(' and ')}; for mixed values declare an `output` struct, " \
                  "or use a binding for open-ended JSON")
      end
      return kinds.first if CompositeTypes::BY_SYMBOL.key?(kinds.first)

      bad(node, "map values can be String, Integer, Float, true/false, or a list of strings or integers so far, not #{shown.first}")
    end

    # A map key: a string literal or a string value, as a &str.
    def map_key(arg, env)
      k = expr(arg, env)
      bad(arg, "map keys are strings, got #{TypeNames.display(k[1])}") unless %i[str string].include?(k[1])
      k[1] == :str ? k[0] : "#{wrap(k)}.as_str()"
    end

    # Reads and non-mutating methods of a map: m["k"] (nil-able), fetch, key?, keys, values, size, empty?, merge.
    def map_call(node, name, args, recv, env)
      value = MAPS.fetch(recv[1])
      unless MAP_ARITY.key?(name)
        bad(node, "a map only supports #{MAP_ARITY.keys.join('/')} so far, not `#{name}`", word: name.to_s, from: MAP_ARITY.keys.map(&:to_s))
      end
      want = MAP_ARITY.fetch(name)
      unless want === args.size
        bad(node, "`#{name}` takes #{want.is_a?(Range) ? 'one or two arguments' : "#{want} argument(s)"} on a map")
      end

      case name
      when :[] then ["#{wrap(recv)}.get(#{map_key(args[0], env)}).cloned()", OPT_OF.fetch(value), true]
      when :fetch then map_fetch(node, recv, args, env, value)
      when :key?, :has_key?, :member?, :include? then ["#{wrap(recv)}.contains_key(#{map_key(args[0], env)})", :bool, true]
      when :keys then ["#{wrap(recv)}.keys().cloned().collect::<Vec<String>>()", :strs, true]
      when :values then map_values(node, recv, value)
      when :size, :length then ["(#{wrap(recv)}.len() as i64)", :i64, true]
      when :empty? then ["#{wrap(recv)}.is_empty()", :bool, true]
      else map_merge(node, recv, args, env)
      end
    end

    # m.fetch("k") ends the call with an error result when the key is missing, as Ruby raises KeyError;
    # m.fetch("k", default) answers the default.
    def map_fetch(node, recv, args, env, value)
      key = map_key(args[0], env)
      if args.size == 1
        @fallible = true
        return ["#{wrap(recv)}.get(#{key}).cloned().ok_or_else(|| format!(\"key not found: {:?}\", #{key}))?", value, false]
      end
      d = expr(args[1], env)
      code = coerce(d[0], d[1], value) or
        bad(args[1], "the default for fetch must be a #{TypeNames.display(value)}, got #{TypeNames.display(d[1])}")
      ["#{wrap(recv)}.get(#{key}).cloned().unwrap_or_else(|| #{unparen(code)})", value, false]
    end

    def map_values(node, recv, value)
      list = { string: :strs, i64: :i64s }[value] or
        bad(node, "`values` needs a map of strings or integers so far (lists of floats, booleans and lists are not supported yet)")
      ["#{wrap(recv)}.values().cloned().collect::<#{CompositeTypes::BY_SYMBOL.fetch(list)[1]}>()", list, true]
    end

    # m.merge(other): a new map with other's entries added (other wins), as in Ruby; m itself is not changed.
    def map_merge(node, recv, args, env)
      o = expr(args[0], env)
      unless [recv[1], :empty_map].include?(o[1])
        bad(args[0], "`merge` takes a map of the same kind (#{TypeNames.display(recv[1])}), got #{TypeNames.display(o[1])}")
      end
      ["{ let mut __m = #{wrap(recv)}.clone(); __m.extend(#{wrap(o)}.clone()); __m }", recv[1], false]
    end

    def list_end(name, recv, elem)
      return ["#{wrap(recv)}.#{name}().copied()", :oi64, true] if elem == :i64

      ["#{wrap(recv)}.#{name}().map(|__x| __x.to_string())", :ostr, true]
    end

    # xs[i]: negative indexes count from the end, and out of range is nil, as in Ruby.
    def list_at(recv, arg, env, elem)
      i = expr(arg, env)
      bad(arg, "a list index must be an integer, got #{i[1]}") unless %i[int i32 i64].include?(i[1])
      item = elem == :i64 ? "__v[__j as usize]" : "__v[__j as usize].to_string()"
      ["{ let __v = &#{wrap(recv)}; let __n = __v.len() as i64; let __i = #{wrap(i)} as i64; " \
       "let __j = if __i < 0 { __i + __n } else { __i }; " \
       "if __j >= 0 && __j < __n { Some(#{item}) } else { None } }", elem == :i64 ? :oi64 : :ostr, false]
    end

    def list_include(recv, arg, env, elem)
      a = expr(arg, env)
      if elem == :i64
        bad(arg, "`include?` on a list of integers takes an integer, got #{a[1]}") unless %i[int i32 i64].include?(a[1])
        return ["#{wrap(recv)}.contains(&(#{wrap(a)} as i64))", :bool, true]
      end
      bad(arg, "`include?` on a list of strings takes a string, got #{a[1]}") unless %i[str string].include?(a[1])
      # The argument is evaluated once, outside the loop, so it may contain `?` or `return`.
      ["{ let __a = &#{wrap(a)}; #{wrap(recv)}.iter().any(|__e| __e.to_string() == *__a) }", :bool, false]
    end

    def join_list(recv, args, elem)
      sep = args[0]
      bad(sep, "join separator must be a plain string literal") if sep && !sep.is_a?(Prism::StringNode)
      lit = RmcpDsl.rstr(sep ? sep.unescaped : "")
      return ["#{wrap(recv)}.join(#{lit})", :string, true] if elem == :string

      ["#{wrap(recv)}.iter().map(|__e| __e.to_string()).collect::<Vec<String>>().join(#{lit})", :string, true]
    end

    # sort (bytewise for strings, like Ruby), uniq (first occurrence wins) and reverse.
    def list_reorder(name, recv, elem)
      ty = elem == :i64 ? "i64" : "String"
      own = elem == :i64 ? "#{wrap(recv)}.iter().copied()" : "#{wrap(recv)}.iter().map(|__e| __e.to_string())"
      code =
        case name
        when :sort then "{ let mut __v: Vec<#{ty}> = #{own}.collect(); __v.sort(); __v }"
        when :reverse then "{ let mut __v: Vec<#{ty}> = #{own}.collect(); __v.reverse(); __v }"
        else "{ let mut __seen = std::collections::HashSet::new(); #{own}.filter(|__s| __seen.insert(__s.clone())).collect::<Vec<#{ty}>>() }"
        end
      [code, LIST_OF.fetch(elem), false]
    end

    # sum of integers, overflow-checked like every other integer addition.
    def list_sum(node, recv)
      @fallible = true
      (@flags["checked"] ||= {})["add:i64"] = true
      ["{ let mut __s: i64 = 0; for __e in #{wrap(recv)}.iter() { __s = ck_add_i64(__s, *__e, " \
       "#{RmcpDsl.rstr(where(node))})?; } __s }", :i64, false]
    end

    # map / select / reject / find / any? / all? / count with a block, as for loops over the borrowed list.
    def list_block(node, name, recv, env, elem)
      return ["(#{wrap(recv)}.len() as i64)", :i64, true] if name == :count && !node.block

      blk = node.block
      bad(node, "`#{name}` needs a literal { |x| ... } block") unless blk.is_a?(Prism::BlockNode)
      param = block_param(blk, env, "`#{name}`", elem)
      st = blk.body
      bad(blk, "empty #{name} block") unless st.is_a?(Prism::StatementsNode)
      lets, e, t, = stmts(st, env.merge(param => elem))
      own = elem == :i64 ? "*__e" : "__e.to_string()"
      value = "{ let #{param} = #{own}; #{(lets + [unparen(e)]).join(' ')} }"
      src = "for __e in #{wrap(recv)}.iter()"
      return list_map(blk, value, t, src) if name == :map

      bad(blk, "the `#{name}` block must return true or false, got #{t}") unless t == :bool
      ety = elem == :i64 ? "i64" : "String"
      case name
      when :select, :reject
        test = name == :select ? value : "!#{value}"
        ["{ let mut __out = Vec::<#{ety}>::new(); #{src} { if #{test} { __out.push(#{own}); } } __out }",
         LIST_OF.fetch(elem), false]
      when :find
        ["{ let mut __r: Option<#{ety}> = None; #{src} { if #{value} { __r = Some(#{own}); break; } } __r }",
         elem == :i64 ? :oi64 : :ostr, false]
      when :any?
        ["{ let mut __r = false; #{src} { if #{value} { __r = true; break; } } __r }", :bool, false]
      when :all?
        ["{ let mut __r = true; #{src} { if !#{value} { __r = false; break; } } __r }", :bool, false]
      else
        ["{ let mut __r: i64 = 0; #{src} { if #{value} { __r += 1; } } __r }", :i64, false]
      end
    end

    # map: a block that returns strings gives a list of strings, one that returns integers a list of integers.
    def list_map(blk, value, type, src)
      kind = if %i[string str].include?(type) then :string
             elsif %i[i32 i64 int].include?(type) then :i64
             end
      bad(blk, "the `map` block must return a string or an integer, got #{type}") unless kind
      push = if kind == :i64 then "#{value} as i64"
             elsif type == :str then "#{value}.to_string()"
             else value
             end
      ["{ let mut __out = Vec::<#{kind == :i64 ? 'i64' : 'String'}>::new(); #{src} { __out.push(#{push}); } __out }",
       LIST_OF.fetch(kind), false]
    end

    # ["a", "b"] is a list of strings and [1, 2] a list of integers; mixing them is refused.
    def array_lit(node, env)
      bad(node, "an array literal needs at least one element") if node.elements.empty?
      items = node.elements.map { |el| expr(el, env) }
      if items.all? { |e| %i[str string].include?(e[1]) }
        ["vec![#{items.map { |e| e[1] == :str ? "#{e[0]}.to_string()" : e[0] }.join(', ')}]", :strs, true]
      elsif items.all? { |e| %i[int i32 i64].include?(e[1]) }
        ["vec![#{items.map { |e| "#{wrap(e)} as i64" }.join(', ')}]", :i64s, true]
      elsif items.all? { |e| e[1] == :block }
        ["vec![#{items.map(&:first).join(', ')}]", :blocks, true]
      else
        bad(node, "array elements must all be strings, all be integers or all be content blocks")
      end
    end

    # (a..b) and (a...b): a list of integers. An empty range (the ends the wrong way round) is an empty list.
    def range_lit(node, env)
      bad(node, "a range needs both ends") unless node.left && node.right
      ends = [node.left, node.right].map do |side|
        e = expr(side, env)
        bad(side, "range ends must be integers, got #{e[1]}") unless %i[int i32 i64].include?(e[1])
        "(#{wrap(e)} as i64)"
      end
      ["(#{ends[0]}#{node.exclude_end? ? '..' : '..='}#{ends[1]}).collect::<Vec<i64>>()", :i64s, true]
    end

    # a.upto(b) and a.downto(b).
    def int_run(name, recv, arg, env)
      b = expr(arg, env)
      bad(arg, "`#{name}` needs an integer, got #{b[1]}") unless %i[int i32 i64].include?(b[1])
      a = "(#{wrap(recv)} as i64)"
      z = "(#{wrap(b)} as i64)"
      code = name == :upto ? "(#{a}..=#{z}).collect::<Vec<i64>>()" : "(#{z}..=#{a}).rev().collect::<Vec<i64>>()"
      [code, :i64s, true]
    end

    # split("sep", limit) with an integer literal limit. A positive limit stops after that many
    # pieces and keeps trailing empty ones; a negative limit splits fully and keeps them; 0 is plain
    # split. The empty string splits to an empty list in every case, as in Ruby.
    def split_limit(recv, args)
      sep, lim = args
      bad(sep, "`split` takes a plain string literal separator") unless sep.is_a?(Prism::StringNode)
      bad(sep, "split(\" \", n) means whitespace in Ruby; use split with no argument") if sep.unescaped == " "
      bad(sep, "split with an empty separator is not supported") if sep.unescaped.empty?
      bad(lim, "the split limit must be an integer literal") unless lim.is_a?(Prism::IntegerNode)
      return split_sep(recv, sep) if lim.value.zero?

      lit = RmcpDsl.rstr(sep.unescaped)
      pieces = lim.value.positive? ? "__s.splitn(#{lim.value}, #{lit})" : "__s.split(#{lit})"
      ["{ let __s = &#{wrap(recv)}; if __s.is_empty() { Vec::<String>::new() } else { " \
       "#{pieces}.map(|__p| __p.to_string()).collect::<Vec<String>>() } }", :strs, false]
    end

    # partition("sep"): [before, sep, after], or [whole, "", ""] when the separator is absent.
    def str_partition(recv, sep)
      bad(sep, "`partition` takes a plain string literal, not a regex") unless sep.is_a?(Prism::StringNode)
      lit = RmcpDsl.rstr(sep.unescaped)
      ["{ let __s = &#{wrap(recv)}; match __s.find(#{lit}) { " \
       "Some(__i) => vec![__s[..__i].to_string(), #{lit}.to_string(), __s[__i + #{lit}.len()..].to_string()], " \
       "None => vec![__s.to_string(), String::new(), String::new()] } }", :strs, false]
    end

    # s[start, length] and s[index]: counted in characters, negative positions count from the end,
    # and out of range is nil, as in Ruby. Ranges are not supported.
    def str_slice(recv, args, env)
      bad(args[0], "string ranges are not supported; use s[start, length]") if args.any? { |a| a.is_a?(Prism::RangeNode) }
      nums = args.map do |a|
        e = expr(a, env)
        bad(a, "a string index must be an integer, got #{e[1]}") unless %i[int i32 i64].include?(e[1])
        "#{wrap(e)} as i64"
      end
      chars = "let __cs: Vec<char> = #{wrap(recv)}.chars().collect(); let __n = __cs.len() as i64;"
      code =
        if nums.size == 1
          "{ #{chars} let __i = #{nums[0]}; let __j = if __i < 0 { __i + __n } else { __i }; " \
          "if __j >= 0 && __j < __n { Some(__cs[__j as usize].to_string()) } else { None } }"
        else
          "{ #{chars} let mut __st = #{nums[0]}; let __ln = #{nums[1]}; if __st < 0 { __st += __n; } " \
          "if __st < 0 || __st > __n || __ln < 0 { None } else { let __en = __st.saturating_add(__ln).min(__n); " \
          "Some(__cs[__st as usize..__en as usize].iter().collect::<String>()) } }"
        end
      [code, :ostr, false]
    end

    # "ab" * 3. A negative count is an error result, as Ruby raises ArgumentError.
    def str_repeat(node, l, r)
      @fallible = true
      ["{ let __n = #{wrap(r)} as i64; if __n < 0 { return Err(format!(\"error: negative argument at {}: " \
       "String#* needs a count of zero or more, got {}\", #{RmcpDsl.rstr(where(node))}, __n)); } " \
       "#{wrap(l)}.repeat(__n as usize) }", :string, false]
    end

    # Integer(text, 10): strict decimal parsing; an invalid value is an error result, like Ruby's
    # ArgumentError. The base must be written out, because Integer(text) alone also accepts 0x, 0b and
    # a leading 0 as octal, which the DSL does not reproduce.
    def integer_call(node, args, env)
      unless args.size == 2 && args[1].is_a?(Prism::IntegerNode) && args[1].value == 10
        bad(node, "Integer needs the base written out: Integer(text, 10); without it Ruby also accepts 0x, 0b and octal forms")
      end
      a = expr(args[0], env)
      bad(args[0], "Integer takes a string, got #{a[1]}") unless %i[str string].include?(a[1])
      @fallible = true
      (@flags["helpers"] ||= {})["str_to_int"] = true
      ["str_to_int(&#{wrap(a)}, #{RmcpDsl.rstr(where(node))})?", :i64, true]
    end

    # String#to_i with Ruby's parsing rules, as an i64: a value that does not fit is an error
    # result, because Ruby would return a bignum. The parser is one small generated function.
    def str_to_i(node, recv)
      @fallible = true
      (@flags["helpers"] ||= {})["str_to_i"] = true
      ["str_to_i(&#{wrap(recv)}, #{RmcpDsl.rstr(where(node))})?", :i64, true]
    end

    def note_capitalize(node)
      Notify.add(@path, node, "W-STR-CAPITALIZE",
                 "Ruby capitalize uses titlecase for some characters (for example ß, ǆ); " \
                 "Rust has only uppercase, so the result can differ for those")
    end

    # rust(:name, args...): a call into a function declared with rust_fn. The signature
    # is checked here; the body of the function is plain Rust that cargo checks.
    def rust_call(node, args, env)
      head = args[0]
      bad(node, "rust() takes the injected function's name as a symbol first") unless head.is_a?(Prism::SymbolNode)
      fname = head.unescaped
      ext = @externs[fname] or bad(head, "no rust_fn declared for `#{fname}`#{@externs.empty? ? '' : " (declared: #{@externs.keys.join(', ')})"}", word: fname, from: @externs.keys)
      (@flags["used_externs"] ||= {})[fname] = true
      rest = args.drop(1)
      unless rest.size == ext["args"].size
        bad(node, "`#{fname}` takes #{ext['args'].size} argument(s), got #{rest.size}; expected `rust(:#{fname}#{ext['args'].map { |t| ", #{t}" }.join})`")
      end
      parts = rest.zip(ext["args"]).map do |arg, want|
        r = expr(arg, env)
        want_t = want.to_sym
        rt = RINT.fetch(r[1], r[1])
        ok = (want_t == :string && %i[string str].include?(rt)) || rt == want_t ||
             (rt == :int && INTS.include?(want_t))
        bad(arg, "argument of `#{fname}` should be #{want_t}, got #{r[1]}") unless ok
        want_t == :string ? "&#{wrap(r)}" : wrap(r)
      end
      prefix = ext["from"] ? "#{ext["from"]}::" : ""
      ["#{prefix}#{fname}(#{parts.join(', ')})", ext["returns"].to_sym, true]
    end

    # Integer arithmetic is overflow-checked: a failure returns a message that says what went
    # wrong, where, and how to fix it (see Emit.checked_int_lines). The compiler decides this;
    # there is no setting. + - * and Ruby-style / % use the add, sub, mul, fdiv and fmod kinds;
    # an operand wrapped in Rust::Int32 / Rust::Int64 switches / and % to the div and rem kinds,
    # which truncate like Rust.
    OP_KIND = { :+ => "add", :- => "sub", :* => "mul", :/ => "fdiv", :% => "fmod" }.freeze
    # Rust::Int32(x) / Rust::Int64(x): the value carries Rust arithmetic (/ and % truncate toward zero)
    # and the carrier is sticky: any operation with such an operand is Rust-style.
    RUST_OP_KIND = OP_KIND.merge(:/ => "div", :% => "rem").freeze
    RUST_INTS = { Int32: :i32, Int64: :i64 }.freeze
    RINT = { r_i32: :i32, r_i64: :i64 }.freeze
    RINT_OF = RINT.invert.freeze

    # Content blocks a tool can return instead of one string (the MCP tool result's `content`): text, image, audio,
    # resource_link and the two embedded resources. The body ends in one block or an array of them. Positional
    # arguments come first (kinds: :string is any string expression, :uri a string that is a URI when written out,
    # :data base64 text, :mime a MIME type written out); then the keywords the block allows. Every block takes
    # `audience:` and `priority:`, the annotations of the spec (the same as on a resource).
    ANNOTATION_KW = { audience: :audience, priority: :priority }.freeze
    CONTENT_SHAPE = {
      text: { pos: %i[string], kw: ANNOTATION_KW },
      image: { pos: %i[data mime], kw: ANNOTATION_KW },
      audio: { pos: %i[data mime], kw: ANNOTATION_KW },
      resource_link: { pos: %i[uri], kw: { name: :string, title: :string, description: :string, mime_type: :mime, size: :size }.merge(ANNOTATION_KW), required: %i[name] },
      embedded_text: { pos: %i[uri string], kw: { mime_type: :mime }.merge(ANNOTATION_KW) },
      embedded_blob: { pos: %i[uri data], kw: { mime_type: :mime }.merge(ANNOTATION_KW) }
    }.freeze
    MIME = %r{\A[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*\z}
    BASE64 = %r{\A(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?\z}
    URI_SCHEME = /\A[A-Za-z][A-Za-z0-9+.-]*:/

    def content_call(node, args, env)
      name = node.name
      unless @tool.to_s.start_with?("tool ")
        bad(node, "`#{name}` builds a content block, which only a tool body can return (a prompt or resource body returns a string)")
      end
      shape = CONTENT_SHAPE.fetch(name)
      kw = args.last.is_a?(Prism::KeywordHashNode) ? args.pop : nil
      unless args.size == shape[:pos].size
        bad(node, "#{name} takes #{shape[:pos].size} positional argument(s) (#{shape[:pos].join(', ')}), got #{args.size}")
      end
      given = content_keywords(node, kw, shape)
      parts = args.zip(shape[:pos]).map { |arg, kind| content_arg(arg, kind, env, name) }
      opts = given.to_h { |key, value| [key, content_arg(value, shape[:kw].fetch(key), env, "#{name} #{key}:")] }
      annotations = content_annotations(opts[:audience], opts[:priority])
      with = ->(chain) { chain + (annotations ? ".with_annotations(#{annotations})" : "") }
      rust =
        case name
        when :text then annotations ? "rmcp::model::ContentBlock::Text(#{with.call("rmcp::model::TextContent::new(#{parts[0]})")})" : "rmcp::model::ContentBlock::text(#{parts[0]})"
        when :image then "rmcp::model::ContentBlock::Image(#{with.call("rmcp::model::ImageContent::new(#{parts[0]}, #{parts[1]})")})"
        when :audio then "rmcp::model::ContentBlock::Audio(#{with.call("rmcp::model::AudioContent::new(#{parts[0]}, #{parts[1]})")})"
        when :resource_link
          link = "rmcp::model::Resource::new(#{parts[0]}, #{opts[:name]})"
          %i[title description mime_type].each { |k| link += ".with_#{k}(#{opts[k]})" if opts[k] }
          link += ".with_size(#{opts[:size]})" if opts[:size]
          "rmcp::model::ContentBlock::resource_link(#{annotations ? "#{link}.with_annotations(#{annotations})" : link})"
        else
          make = name == :embedded_text ? "text" : "blob"
          inner = "rmcp::model::ResourceContents::#{make}(#{parts[1]}, #{parts[0]})#{".with_mime_type(#{opts[:mime_type]})" if opts[:mime_type]}"
          "rmcp::model::ContentBlock::Resource(#{with.call("rmcp::model::EmbeddedResource::new(#{inner})")})"
        end
      [rust, :block, true]
    end

    def content_keywords(node, kw, shape)
      given = {}
      (kw ? kw.elements : []).each do |el|
        bad(el, "unsupported #{nodename(el)} in #{node.name}(...) (use `keyword: value`)") unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
        key = el.key.unescaped.to_sym
        bad(el, "#{node.name} has no keyword `#{key}:` (it has: #{shape[:kw].keys.map { |k| "#{k}:" }.join(', ')})", word: key, from: shape[:kw].keys) unless shape[:kw].key?(key)
        bad(el, "duplicate `#{key}:`") if given.key?(key)
        given[key] = el.value
      end
      missing = (shape[:required] || []) - given.keys
      bad(node, "#{node.name} needs #{missing.map { |k| "`#{k}:`" }.join(', ')}") unless missing.empty?
      given
    end

    # One argument of a content block, as Rust. A literal is checked here (MIME type, base64, URI scheme, annotation
    # values); an expression only has to be a string.
    def content_arg(node, kind, env, what)
      case kind
      when :mime
        bad(node, "#{what}: the MIME type is written out, such as \"image/png\"") unless node.is_a?(Prism::StringNode)
        bad(node, "#{what}: `#{node.unescaped}` is not a MIME type (type/subtype, such as image/png)") unless node.unescaped.match?(MIME)
        RmcpDsl.rstr(node.unescaped)
      when :size
        ok = node.is_a?(Prism::IntegerNode) && node.value >= 0
        bad(node, "#{what}: the size is a number of bytes written out, zero or more") unless ok
        "#{node.value}u64"
      when :audience
        ok = node.is_a?(Prism::ArrayNode) && !node.elements.empty? && node.elements.all? { |el| el.is_a?(Prism::SymbolNode) && %w[user assistant].include?(el.unescaped) }
        bad(node, "#{what}: a list of :user and/or :assistant, such as [:user]") unless ok
        node.elements.map(&:unescaped).uniq
      when :priority
        ok = (node.is_a?(Prism::IntegerNode) || node.is_a?(Prism::FloatNode)) && (0..1).cover?(node.value)
        bad(node, "#{what}: a number from 0 to 1 written out (1 is the most important)") unless ok
        node.value.to_f
      else
        text_arg(node, kind, env, what)
      end
    end

    def text_arg(node, kind, env, what)
      if node.is_a?(Prism::StringNode)
        literal = node.unescaped
        bad(node, "#{what}: `#{literal.length > 24 ? "#{literal[0, 24]}..." : literal}` is not base64 text (A-Z a-z 0-9 + /, padded with =)") if kind == :data && !literal.match?(BASE64)
        bad(node, "#{what}: `#{literal}` is not a URI (it needs a scheme, such as file:///a.txt or notekit://guide)") if kind == :uri && !literal.match?(URI_SCHEME)
        return "#{RmcpDsl.rstr(literal)}.to_string()"
      end
      e = expr(node, env)
      bad(node, "#{what}: needs a string, got #{TypeNames.display(e[1])}") unless %i[string str].include?(e[1])
      return "#{e[0]}.to_string()" if e[1] == :str

      # a local or parameter is read again later, so the block takes a copy
      node.is_a?(Prism::LocalVariableReadNode) ? "#{wrap(e)}.clone()" : e[0]
    end

    def content_annotations(audience, priority)
      return nil unless audience || priority

      ann = "rmcp::model::Annotations::default()"
      ann += ".with_audience(vec![#{audience.map { |a| "rmcp::model::Role::#{a.capitalize}" }.join(', ')}])" if audience
      ann += ".with_priority(#{priority})" if priority
      ann
    end

    # A value of a type a binding owns (class Value < RmcpDsl::Opaque): held and passed on, never looked into.
    def opaque?(sym) = CompositeTypes::Opaque.symbol?(sym)

    def opaque_name(sym) = CompositeTypes::Opaque.name_of(sym)

    # Heck.snake_case(text): a call into a binding. Arguments are checked against the binding's sig
    # here; the generated wrapper function (Emit.binding_fn) is rustc-checked against the same sig.
    def binding_call(node, args, env)
      file = @bindings.fetch(node.receiver.name.to_s)
      fn = file.fns[node.name.to_s] or
        bad(node, "#{file.module_name} has no method `#{node.name}` (it has: #{file.fns.keys.join(', ')})", word: node.name, from: file.fns.keys)
      unless args.size == fn.params.size
        bad(node, "#{file.module_name}.#{fn.name} takes #{fn.params.size} argument(s), got #{args.size}; expected `#{file.module_name}.#{fn.name}(#{fn.params.map(&:first).join(', ')})`")
      end
      parts = args.zip(fn.params).map do |arg, (pname, ptype)|
        r = expr(arg, env)
        rt = RINT.fetch(r[1], r[1])
        ok = (ptype == :string && %i[string str].include?(rt)) || rt == ptype || (rt == :int && INTS.include?(ptype))
        bad(arg, "#{file.module_name}.#{fn.name}: argument `#{pname}` should be #{TypeNames.display(ptype)}, got #{TypeNames.display(rt)}") unless ok
        %i[string strs i64s].include?(ptype) || opaque?(ptype) ? "&#{wrap(r)}" : wrap(r)
      end
      (@flags["used_bindings"] ||= {})["#{file.module_name}.#{fn.name}"] = true
      ["#{file.wrapper(fn)}(#{parts.join(', ')})", fn.returns, true]
    end

    # A binding method written in Ruby (no rust template): the Ruby body IS the implementation.
    def lower_def(fn)
      node = fn.node
      env = fn.params.to_h { |n, t| [n.to_sym, t] }
      fn.params.each_with_index { |(n, _), i| @declared << [n.to_sym, node.parameters.requireds[i], "parameter"] }
      st = node.body
      bad(node, "`#{fn.name}` has an empty body") unless st.is_a?(Prism::StatementsNode)
      unless fn.returns == :string
        bad(node, "a binding compiled from Ruby must return String for now, but the sig says #{fn.returns}")
      end
      lets, e, t, = stmts(st, env)
      bad(st, "`#{fn.name}` must return a string, got #{t}; use .to_s") unless %i[string str].include?(t)
      e = "#{e}.to_string()" if t == :str
      reject_unused
      { "locals" => lets, "expr" => e, "fallible" => @fallible }
    end
    public :lower_def # the reader calls it from outside; everything around it is private

    # Rust::Int32(x) / Rust::Int64(x): mark an integer as "treat this like Rust".
    def rust_int(node, args, env)
      base = RUST_INTS[node.name] or
        bad(node, "unknown Rust type `Rust::#{node.name}` (known: #{RUST_INTS.keys.map { |k| "Rust::#{k}" }.join(', ')})", word: node.name, from: RUST_INTS.keys)
      bad(node, "Rust::#{node.name} takes exactly one integer") unless args.size == 1
      r = expr(args[0], env)
      rb = RINT.fetch(r[1], r[1])
      bad(args[0], "Rust::#{node.name} wraps an #{base} value, got #{rb}") unless rb == base || rb == :int
      [wrap(r), RINT_OF.fetch(base), true]
    end

    def where(node)
      loc = node.location
      tool = @tool ? " in #{@tool}" : ""
      "#{@path}:#{loc.start_line}:#{loc.start_column + 1}#{tool}"
    end

    # Each operation and type becomes one small generated function (ck_add_i32, ck_fdiv_i64, ...),
    # recorded in @flags["checked"] so Emit writes exactly the ones this server uses.
    def checked_op(node, op, l, r, t, rust)
      @fallible = true
      kind = (rust ? RUST_OP_KIND : OP_KIND).fetch(op)
      (@flags["checked"] ||= {})["#{kind}:#{t}"] = true
      ["ck_#{kind}_#{t}(#{wrap(l)}, #{wrap(r)}, #{RmcpDsl.rstr(where(node))})?", rust ? RINT_OF.fetch(t) : t, true]
    end

    def checked_neg(node, recv)
      @fallible = true
      t = RINT.fetch(recv[1], recv[1])
      (@flags["checked"] ||= {})["neg:#{t}"] = true
      ["ck_neg_#{t}(#{wrap(recv)}, #{RmcpDsl.rstr(where(node))})?", recv[1], true]
    end

    def note_strip(node)
      Notify.add(@path, node, "W-STR-STRIP-RUBY",
                 "Ruby strip (NUL and ASCII whitespace) compiles to an explicit-set trim, not Rust trim()")
    end

    # s.gsub(/re/) { |m| ... } and s.sub(/re/) { |m| ... }: the block receives the matched text and
    # returns the replacement. Only a regex literal is supported as the pattern, and the block cannot
    # read capture groups ($1, $~) or contain raise, to_i or integer arithmetic yet.
    def subst_block(node, name, recv, args, env)
      unless args.size == 1 && args[0].is_a?(Prism::RegularExpressionNode)
        bad(node, "`#{name}` with a block takes one regex literal as its pattern")
      end
      blk = node.block
      param = block_param(blk, env, "`#{name}`", :string)
      st = blk.body
      bad(blk, "empty #{name} block") unless st.is_a?(Prism::StatementsNode)
      outer = @fallible
      @fallible = false
      lets, e, t, = stmts(st, env.merge(param => :string))
      e = unparen(e)
      if @fallible
        bad(blk, "integer arithmetic, `to_i`, `raise` or `return` inside a #{name} block is not supported yet; do it outside the block")
      end
      @fallible = outer
      bad(blk, "the `#{name}` block must return a string, got #{t}") unless %i[string str].include?(t)
      e = "#{e}.to_string()" if t == :str
      meth = name == :gsub ? "replace_all" : "replace"
      ["#{regex_id(args[0])}.#{meth}(&#{wrap(recv)}, |__c: &regex::Captures| { let #{param} = __c[0].to_string(); " \
       "#{(lets + [e]).join(' ')} }).into_owned()", :string, true]
    end

    # gsub/sub with a string literal -> str::replace/replacen; with a regex literal ->
    # a compiled regex static. Replacement is literal text (NoExpand): no backslash.
    def subst(node, name, recv, args, env = nil)
      bad(node, "`#{name}` needs a string receiver, got #{recv[1]}") unless %i[str string].include?(recv[1])
      return subst_block(node, name, recv, args, env) if node.block

      bad(node, "`#{name}` takes exactly two arguments, or one regex literal and a block; expected `#{name}(pattern, replacement)` or `#{name}(/re/) { |m| ... }`") unless args.size == 2
      pat, repl = args
      unless repl.is_a?(Prism::StringNode) && !repl.unescaped.include?("\\")
        bad(repl, "replacement must be a plain string literal without a backslash")
      end
      r = RmcpDsl.rstr(repl.unescaped)
      code =
        case pat
        when Prism::StringNode
          a = RmcpDsl.rstr(pat.unescaped)
          name == :gsub ? "#{wrap(recv)}.replace(#{a}, #{r})" : "#{wrap(recv)}.replacen(#{a}, #{r}, 1)"
        when Prism::RegularExpressionNode
          meth = name == :gsub ? "replace_all" : "replace"
          "#{regex_id(pat)}.#{meth}(&#{wrap(recv)}, regex::NoExpand(#{r})).into_owned()"
        else
          bad(pat, "`#{name}` needs a string or regex literal as its first argument, got #{nodename(pat)}")
        end
      [code, :string, true]
    end

    # Registers (or reuses) a compiled regex static and returns its name.
    def regex_id(node)
      bad(node, "regex flag `o` is not supported") if node.once?
      rust = RegexTranslate.translate(node.unescaped, multi_line: node.multi_line?,
                                                      ignore_case: node.ignore_case?, extended: node.extended?)
      found = @regexes.find { |r| r["pattern"] == rust }
      return found["id"] if found

      id = "RE_#{@regexes.size + 1}"
      @regexes << { "id" => id, "pattern" => rust }
      id
    rescue RegexTranslate::Unsupported => e
      bad(node, "unsupported regex: #{e.message}")
    end

    def norm(t) = (t = RINT.fetch(t, t)) == :str ? :string : t

    def unify(n, a, b)
      return a if a == b
      return b if a == :never # `raise` has no value, so it fits any type
      return a if b == :never
      return b if a == :int && INTS.include?(b)
      return a if b == :int && INTS.include?(a)
      bad(n, "type mismatch: #{a} vs #{b}")
    end
  end
end

