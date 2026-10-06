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
                         squeeze to_i each select reject find any? all? count sort uniq partition chars lines times upto downto
                         sum min max to_a fetch key? has_key? member? keys values merge tally =~
                         client_name client_version protocol_version request_id progress_token cancelled?].freeze
    # The request-context values a tool body may read, as [Rust, type]. Using one makes the generated tool fn
    # take a `RequestContext` parameter (Emit#tool_fn); the nil-able ones follow the usual `|| default`,
    # `.nil?` and `.to_s` rules. `request_id` is a String and `cancelled?` a bool.
    CONTEXT_BUILTINS = {
      client_name: ["__ctx.client_info().map(|i| i.name.clone())", :ostr],
      client_version: ["__ctx.client_info().map(|i| i.version.clone())", :ostr],
      protocol_version: ["__ctx.protocol_version().map(|v| v.to_string())", :ostr],
      request_id: ["__ctx.id.to_string()", :string],
      progress_token: ["__ctx.meta.get_progress_token().map(|t| t.0.to_string())", :ostr],
      cancelled?: ["__ctx.ct.is_cancelled()", :bool]
    }.freeze
    # The surface of the `progress(value, total:, message:)` statement: one numeric value and the optional
    # keywords. It is a statement, not a value, so it is not an entry in CONTEXT_BUILTINS.
    PROGRESS_SHAPE = { pos: %i[number], kw: { total: :number, message: :string } }.freeze
    # The statement built-ins that change the advertised tool list: `hide_tool(:name)` hides one of the
    # server's tools and `show_tool(:name)` shows it again. A tool body only; each tells clients with
    # notifications/tools/list_changed.
    TOOL_VISIBILITY_BUILTINS = { hide_tool: true, show_tool: false }.freeze
    # The MCP logging levels accepted by the `log(level, message)` statement (gated by `feature :logging`),
    # mapped to the rmcp enum variant. SEP-2577 deprecates logging, so the emitted call is scoped with
    # #[allow(deprecated)] and the generated crate stays warning-free.
    LOG_LEVELS = { debug: "Debug", info: "Info", notice: "Notice", warning: "Warning",
                   error: "Error", critical: "Critical", alert: "Alert", emergency: "Emergency" }.freeze
    # The surface of the `elicit(message, schema: { ... })` call in a tool body: a string message and a
    # JSON object literal turned into an ElicitationSchema at run time. It is a value, not a statement.
    ELICIT_SHAPE = { pos: [:string], kw: { schema: :schema }, required: [:schema] }.freeze
    # `roots()` asks the client for its roots (a server-to-client `roots/list` request) and returns a list of
    # Root values, each with a `uri` and a nil-able `name`. SEP-2577 deprecates roots, so the emitted call is
    # scoped with #[allow(deprecated)]. The element type reuses the struct-field reader through this synthetic
    # struct (uri: String, name: String?).
    ROOT_TYPE = :"struct:Root"
    ROOT_STRUCT = { "name" => "Root",
                    "fields" => [{ "name" => "uri", "type" => "string" },
                                 { "name" => "name", "type" => "string", "optional" => true }] }.freeze
    # `sample(prompt, max_tokens:, ...)` in a tool body asks the client for an LLM completion (a
    # server-to-client `sampling/createMessage` request) and returns a Sample value: the assistant `text`
    # (nil-able, so non-text content is visible as none), the `model`, the nil-able `stop_reason` and the
    # `role`. SEP-2577 deprecates sampling, so the emitted call is scoped with #[allow(deprecated)]. The value
    # is a local Rust struct with these fields, so the ordinary struct-field reader reads them.
    SAMPLE_TYPE = :"struct:Sample"
    SAMPLE_SHAPE = { pos: [:string], kw: { max_tokens: :int, system: :string, temperature: :number, stop: :strs },
                     required: [:max_tokens] }.freeze
    SAMPLE_STRUCT = { "name" => "Sample",
                      "fields" => [{ "name" => "text", "type" => "string", "optional" => true },
                                   { "name" => "model", "type" => "string" },
                                   { "name" => "stop_reason", "type" => "string", "optional" => true },
                                   { "name" => "role", "type" => "string" }] }.freeze

    # Values that may be nil in Ruby (list indexing, index): Option in Rust. Only `|| default`,
    # `.nil?` and `.to_s` may consume them, so a missing value is never silently used.
    OPT_FIXED = { ostr: :string, oi64: :i64, oi32: :i32, of64: :f64, obool: :bool, ostrs: :strs, oi64s: :i64s, of64s: :f64s, ojson: :json }.freeze
    OPT = CompositeTypes::OptTable.new(OPT_FIXED)
    OPT_OF = CompositeTypes::OptOfTable.new(OPT_FIXED.invert) # element type -> nil-able type, for optional fields
    # Typed maps (T::Hash[String, V]); see CompositeTypes. Like a list they are only ever borrowed.
    MAPS = CompositeTypes::MapTable.new
    MAP_ARITY = { :[] => 1, :fetch => 1..2, :key? => 1, :has_key? => 1, :member? => 1, :include? => 1, :keys => 0,
                  :values => 0, :size => 0, :length => 0, :empty? => 0, :merge => 1, :map => 0, :select => 0, :reject => 0, :each => 0 }.freeze
    LIST_BLOCK = %i[each select reject find any? all? count].freeze
    # List types and their element types. Code that differs between the kinds lives in list_call and its
    # helpers; everything else treats a list as opaque.
    LISTS = { strs: :string, i64s: :i64, f64s: :f64 }.freeze
    LIST_OF = LISTS.invert.freeze
    # The methods a list of another params struct supports. Ordering, equality and stringification (sort,
    # uniq, include?, join, sum, min, max) are refused: the elements have no order or equality of their own.
    STRUCT_LIST_METHODS = %i[length size empty? first last [] each map select reject find any? all? count reverse].freeze
    LIST_ARITY = { length: 0, size: 0, empty?: 0, first: 0, last: 0, sort: 0, uniq: 0, reverse: 0, to_a: 0,
                   sum: 0, min: 0, max: 0, join: 0..1, :[] => 1, include?: 1, map: 0, select: 0, reject: 0, each: 0,
                   find: 0, any?: 0, all?: 0, count: 0, tally: 0 }.freeze
    INT_LIST_METHODS = %i[sum min max].freeze
    FLOAT_LIST_METHODS = %i[sum min max].freeze
    LIST_METHODS = (%i[length size map join first last [] empty? include? sort uniq reverse to_a tally] + LIST_BLOCK).freeze
    # One-string-argument tests: Ruby method => Rust str method. Regex arguments are refused (use match?).
    STR_TESTS = { start_with?: "starts_with", end_with?: "ends_with", include?: "contains" }.freeze
    # Ruby split with no argument: ASCII whitespace separators only (no NBSP, no NUL).
    SPLIT_WS = %q(|c: char| matches!(c, ' ' | '\t' | '\n' | '\u{b}' | '\u{c}' | '\r'))
    # Ruby String#strip: NUL, tab, LF, VT, FF, CR and space. Rust trim() differs
    # (Unicode whitespace, no NUL), so the set is spelled out. See spec/shims/string.yml.
    STRIP_FN = %q(|c: char| matches!(c, '\u{0}' | '\t' | '\n' | '\u{b}' | '\u{c}' | '\r' | ' '))

    def initialize(path, params, regexes = [], externs = {}, flags = {}, tool = nil, bindings = {}, helpers = {}, structs = [], outputs = [], mime_type: nil)
      @path = path
      @outputs = outputs # structured results a tool may build with Name.new(...)
      @structs = structs + [ROOT_STRUCT, SAMPLE_STRUCT] # every params struct, so a nested object's fields can be read (and the roots element and the sample result)
      @helpers = helpers # helpers declared above this body: name -> record (see Reader#helper_decl)
      @ret = :string     # what `return` must return: a tool returns a string, a helper its declared type
      @helper = false
      @bindings = bindings
      @regexes = regexes
      @externs = externs
      @flags = flags
      @tool = tool
      @fallible = false
      @uses_context = false # a tool body read a request-context built-in (CONTEXT_BUILTINS)
      @uses_async = false   # a tool body (or a helper it calls) awaits, so its fn is async
      @async_reason = nil   # the first construct that made the body async, for diagnostics and hover
      @uses_tool_visibility = false # a tool body hides or shows a tool (hide_tool/show_tool)
      @uses_elicit = false  # a tool body asked the client for input (elicitation), so the crate needs the feature

      @read = {}       # names of locals / block parameters that are read somewhere
      @declared = []   # [name, node, what] for every local and block parameter declared
      @mime_type = mime_type # the resource mime_type, the default of a resource content keyword
      @used_read_uri = false # a resource content took the read uri as its default
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
      elsif t == :secret
        bad(st, "a secret cannot be returned; pass it to a binding or rust_fn function and return what that gives back")
      elsif %i[block blocks].include?(t)
        e = "vec![#{e}]" if t == :block
      elsif %i[rcontent rcontents].include?(t)
        e = "vec![#{e}]" if t == :rcontent
      else
        built = resource_body? ? "text(...) or blob(...)" : "text(...) or image(...)"
        bad(st, "body must return a string, got #{TypeNames.display(t)}; use .to_s, or end it in a content block such as #{built}") unless %i[string str].include?(t)
        e = "#{e}.to_string()" if t == :str
      end
      reject_unused
      type = output ? "struct:#{output}" : (%i[block blocks].include?(t) ? "blocks" : (%i[rcontent rcontents].include?(t) ? "rcontents" : "string"))
      { "args" => names, "locals" => lets, "expr" => e, "type" => type, "fallible" => @fallible,
        "uses_context" => @uses_context, "uses_async" => @uses_async, "async_reason" => @async_reason, "uses_uri" => @used_read_uri,
        "uses_elicit" => @uses_elicit, "tool_visibility" => @uses_tool_visibility }

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

    # [let-lines, final expr, type, atomic]; only `name = expr`, a guard clause, `progress(...)`, `log(...)`, `hide_tool(...)`, `show_tool(...)` or `.each { ... }` may precede the last expression.
    def stmts(st, env)
      init = st.body[0...-1]
      lets = init.flat_map { |n| statement(n, env) }
      [lets, *expr(st.body.last, env)]
    end

    # One statement before a body's or an each block's last expression: a local, a guard clause, a
    # progress or tool-visibility call, or an each loop. Anything else is refused.
    def statement(n, env)
      return log_stmt(n, env) if log_call?(n)
      return progress_stmt(n, env) if progress_call?(n)
      return tool_visibility_stmt(n) if tool_visibility_call?(n)
      return [guard(n, env)] if n.is_a?(Prism::IfNode) || n.is_a?(Prism::UnlessNode)
      return each_stmt(n, env) if each_call?(n)

      let_stmt(n, env)
    end

    # `name = expr` as a statement. The local is declared once and may not be reassigned.
    def let_stmt(n, env)
      bad(n, "unsupported #{nodename(n)} as a statement (only `name = expr`, a guard clause, `progress(...)`, `log(...)`, `hide_tool(...)`, `show_tool(...)` or `.each { ... }` before the last expression)") unless n.is_a?(Prism::LocalVariableWriteNode)
      bad(n, "`#{n.name}` is already defined (no reassignment)") if env.key?(n.name)
      bad(n, "local `#{n.name}` must be snake_case and not a Rust keyword") if !n.name.to_s.match?(SNAKE) || RUST_KW.include?(n.name.to_s)
      e, t, = expr(n.value, env)
      env[n.name] = t
      @declared << [n.name, n, "local"]
      note_decl(n.name_loc, n.name, "local", t)
      ["let #{n.name} = #{e};"]
    end

    # Is this node a bare `.each { ... }` call in statement position? It must have a receiver and a block.
    def each_call?(node)
      node.is_a?(Prism::CallNode) && node.name == :each && node.receiver && node.block
    end

    # `xs.each { |x| ... }` / `m.each { |k, v| ... }` as a statement: run the block for its effects
    # (raise, return, progress, a helper call) and drop the receiver Ruby's each would return. The
    # block's value is ignored, unlike map, which must produce a string or an integer.
    def each_stmt(node, env)
      args = node.arguments ? node.arguments.arguments : []
      bad(node, "`each` takes no arguments; write `xs.each { |x| ... }`") unless args.empty?
      recv = expr(node.receiver, env)
      bad(node, "a secret has no methods (not `each`): it can only be passed to a binding or rust_fn function") if recv[1] == :secret
      bad(node, "this value may be nil; use `|| default`, `.nil?` or `.to_s` (not `each`)") if OPT.key?(recv[1])
      bad(node, "#{opaque_name(recv[1])} is an opaque value with no methods of its own (not `each`); pass it to a function of its binding") if opaque?(recv[1])
      bad(node, "`each` needs a list or a map, got #{TypeNames.display(recv[1])}") unless LISTS.key?(recv[1]) || struct_list?(recv[1]) || MAPS.key?(recv[1]) || recv[1] == :roots_result

      [each_loop(node, recv, env, wrap(recv))]
    end

    # `each` as an expression: Ruby's each returns its receiver, so the loop runs and the receiver
    # is cloned out. A list is only ever borrowed, so the receiver is bound once for both uses.
    def each_expr(node, recv, env)
      ["{ let __v = &#{wrap(recv)}; #{each_loop(node, recv, env, '__v')} (*__v).clone() }", recv[1], false]
    end

    # The for loop of an each block (a list or a map), shared by the statement and expression
    # positions. The block's value is ignored, so it may end in a guard clause or a progress call;
    # a trailing value expression is emitted and dropped.
    def each_loop(node, recv, env, iterable)
      blk = node.block
      bad(node, "`each` needs a literal { |x| ... } block") unless blk.is_a?(Prism::BlockNode)
      st = blk.body
      bad(blk, "empty each block") unless st.is_a?(Prism::StatementsNode)
      if LISTS.key?(recv[1])
        elem = LISTS.fetch(recv[1])
        param = block_param(blk, env, "`each`", elem)
        body = each_block_stmts(st, env.merge(param => elem))
        "for __e in #{iterable}.iter() { let #{param} = #{elem == :i64 ? '*__e' : '__e.to_string()'}; #{body.join(' ')} }"
      elsif struct_list?(recv[1])
        elem = :"struct:#{struct_list_name(recv[1])}"
        param = block_param(blk, env, "`each`", elem)
        body = each_block_stmts(st, env.merge(param => elem))
        "for __e in #{iterable}.iter() { let #{param} = (*__e).clone(); #{body.join(' ')} }"
      elsif recv[1] == :roots_result
        param = block_param(blk, env, "`each`", ROOT_TYPE)
        body = each_block_stmts(st, env.merge(param => ROOT_TYPE))
        "for __e in #{iterable}.iter() { let #{param} = (*__e).clone(); #{body.join(' ')} }"
      elsif CompositeTypes.map_list_sym?(recv[1])
        elem = CompositeTypes.map_list_value(recv[1])
        param = block_param(blk, env, "`each`", elem)
        body = each_block_stmts(st, env.merge(param => elem))
        "for __e in #{iterable}.iter() { let #{param} = (*__e).clone(); #{body.join(' ')} }"
      else
        value = MAPS.fetch(recv[1])
        kname, vname = map_block_params(blk, env, :each, value)
        body = each_block_stmts(st, env.merge(kname => :string, vname => value))
        "for (__k, __v) in #{iterable}.iter() { let #{kname} = __k.to_string(); let #{vname} = #{map_block_value(value)}; #{body.join(' ')} }"
      end
    end

    # The statements of an each block. Its value is discarded, so its last statement may be a guard
    # clause, a progress or log call or another each; any other trailing expression is emitted and dropped.
    def each_block_stmts(st, env)
      st.body.flat_map do |n|
        if log_call?(n) || progress_call?(n) || tool_visibility_call?(n) || each_call?(n) || n.is_a?(Prism::LocalVariableWriteNode) || guard_clause?(n)
          statement(n, env)
        else
          e, = expr(n, env)
          ["#{unparen(e)};"]
        end
      end
    end

    # A guard clause is an `if`/`unless` with no else; only those may stand as a statement.
    def guard_clause?(n)
      (n.is_a?(Prism::IfNode) && n.subsequent.nil?) || (n.is_a?(Prism::UnlessNode) && n.else_clause.nil?)
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

    # A stand-in for a Prism::Location when only a name's own span is wanted: a keyword parameter's
    # location includes its trailing colon, which the editor should not underline.
    NameSpan = Struct.new(:start_line, :start_column, :end_line, :end_column)

    def name_span(node, name)
      loc = node.respond_to?(:name_loc) ? node.name_loc : node.location
      NameSpan.new(loc.start_line, loc.start_column, loc.start_line, loc.start_column + name.to_s.bytesize)
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

    # A nested object, required (:"struct:Name") or optional (:"opt<struct:Name>").
    def object_type?(sym)
      sym.to_s.start_with?("struct:") || (OPT.key?(sym) && OPT[sym].to_s.start_with?("struct:"))
    end

    # A list of another params struct (:"list<struct:Name>"); its element type is :struct:Name.
    def struct_list?(sym) = CompositeTypes.object_list_sym?(sym)

    def struct_list_name(sym) = CompositeTypes.object_list_element(sym)

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
          bad(part, "this value may be nil; use `|| default` or `.to_s` inside the string") if OPT.key?(v[1]) && !object_type?(v[1])
          bad(part, "a list cannot go inside a string; use join") if LISTS.key?(v[1])
          bad(part, "a list of objects cannot go inside a string; map it to strings first") if struct_list?(v[1])
          bad(part, "a map cannot go inside a string; read one value with m[\"key\"] (or join its keys)") if MAPS.key?(v[1])
          bad(part, "#{opaque_name(v[1])} is an opaque value; pass it to a function of its binding to get a string out") if opaque?(v[1])
          bad(part, "an object cannot go inside a string; read one of its fields") if object_type?(v[1])
          bad(part, "a content block cannot go inside a string; return it from the body") if %i[block blocks].include?(v[1])
          bad(part, "a secret cannot go inside text, where it could be returned or logged; pass it to a binding or rust_fn function") if v[1] == :secret
          vals << (v[1] == :f64 ? f64_str(v[0]) : v[0])
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
      return safe_nav_call(n, env) if n.safe_navigation?
      return rust_int(n, args, env) if n.receiver.is_a?(Prism::ConstantReadNode) && n.receiver.name == :Rust
      if n.receiver.is_a?(Prism::ConstantReadNode)
        return binding_call(n, args, env) if @bindings.key?(n.receiver.name.to_s)

        bad(n.receiver, "unknown constant `#{n.receiver.name}`; bindings are loaded with use_bindings :name#{@bindings.empty? ? '' : " (loaded: #{@bindings.keys.join(', ')})"}",
            word: n.receiver.name, from: @bindings.keys + ["Rust"])
      end
      return rust_call(n, args, env) if name == :rust && n.receiver.nil?
      return raise_call(n, args, env) if name == :raise && n.receiver.nil?
      return output_new(n, args, env) if name == :result && n.receiver.nil?
      return setting_call(n, args) if name == :setting && n.receiver.nil?
      return elicit_call(n, args, env) if name == :elicit && n.receiver.nil?
      return roots_call(n, args, env) if name == :roots && n.receiver.nil?
      return sample_call(n, args, env) if name == :sample && n.receiver.nil?

      bad(n, "`progress` is a statement, not a value; write it on its own line") if n.receiver.nil? && name == :progress
      bad(n, "`log` is a statement, not a value; write it on its own line") if n.receiver.nil? && name == :log
      bad(n, "`hide_tool` is a statement, not a value; write it on its own line") if n.receiver.nil? && name == :hide_tool
      bad(n, "`show_tool` is a statement, not a value; write it on its own line") if n.receiver.nil? && name == :show_tool
      return context_call(n, name, args) if n.receiver.nil? && CONTEXT_BUILTINS.key?(name)

      return integer_call(n, args, env) if name == :Integer && n.receiver.nil?

      return helper_call(n, args, env) if n.receiver.nil? && @helpers.key?(name.to_s)
      if n.receiver.nil? && RESOURCE_CONTENT.key?(name)
        return resource_content_call(n, args, env) if resource_body?
        # `text` is also a content builder in a tool or prompt; only `blob` is resource-only.
        bad(n, "`blob` builds a resource content, which only a resource body can return") if name == :blob
      end
      return content_call(n, args, env) if n.receiver.nil? && CONTENT_SHAPE.key?(name)

      unless n.receiver
        bad(n, "unsupported call `#{name}` (needs a receiver); a helper can only be called after it is declared, and only from a tool or a later helper" \
               "#{@helpers.empty? ? '' : " (declared helpers: #{@helpers.keys.join(', ')})"}", word: name, from: @helpers.keys)
      end

      recv = expr(n.receiver, env)
      bad(n, "a secret has no methods (not `#{name}`): it can only be passed to a binding or rust_fn function") if recv[1] == :secret
      return roots_method(n, name, args, recv, env) if recv[1] == :roots_result
      return elicit_field(n, name, recv) if recv[1] == :elicit_result && args.empty?
      return struct_field(n, name, recv) if recv[1].to_s.start_with?("struct:") && args.empty?


      if recv[1] == :regex && !%i[gsub sub].include?(name)
        bad(n, "a regex literal can only be the first argument of gsub/sub")
      end
      if OPT.key?(recv[1])
        inner = OPT[recv[1]]
        if inner.to_s.start_with?("struct:") && name != :nil?
          bad(n, "`#{n.receiver.slice}` may be nil, so read its fields with `&.` (write `#{n.receiver.slice}&.#{name}`) or test `.nil?` first")
        end
        if MAPS.key?(inner) # m["a"] on a map of maps: index the inner map too; a missing outer key gives nil
          return opt_map_call(n, name, args, recv, env, inner)
        end
        soft = LISTS.key?(inner) || struct_list?(inner) || MAPS.key?(inner) || opaque?(inner) || inner.to_s.start_with?("struct:")
        allowed = soft ? %i[nil?] : %i[nil? to_s]
        bad(n, "this value may be nil; use `|| default`, `.nil?` or `.to_s` (not `#{name}`)") unless allowed.include?(name)
      end
      bad(n, "#{opaque_name(recv[1])} is an opaque value with no methods of its own (not `#{name}`); pass it to a function of its binding") if opaque?(recv[1])
      return list_call(n, name, args, recv, env) if LISTS.key?(recv[1])
      return struct_list_call(n, name, args, recv, env) if struct_list?(recv[1])
      return map_list_call(n, name, args, recv, env) if CompositeTypes.map_list_sym?(recv[1])
      return map_call(n, name, args, recv, env) if MAPS.key?(recv[1])
      return match_op(n, args, recv) if name == :=~

      if (ARITH + ORDER + EQ).include?(name) && args.size == 1
        binop(n, name, recv, expr(args[0], env))
      elsif OPT.key?(recv[1]) && name == :to_s && args.empty?
        opt_to_s(recv)
      elsif OPT.key?(recv[1]) && name == :nil? && args.empty?
        ["#{wrap(recv)}.is_none()", :bool, true]
      elsif name == :to_s && args.empty? && recv[1] == :f64
        [f64_str(wrap(recv)), :string, false]
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

    # `s =~ /re/`: the character index of the first match, or nil (Ruby counts characters, not
    # bytes). v1 takes a regex literal only and a string receiver only; it is an index, never a
    # boolean, so anything else is refused rather than quietly turned into true or false.
    def match_op(node, args, recv)
      bad(node, "`=~` takes exactly one argument (a regex literal), got #{args.size}") unless args.size == 1
      bad(node, "`=~` needs a string receiver, got #{TypeNames.display(recv[1])}") unless %i[str string].include?(recv[1])
      pat = args[0]
      bad(pat, "`=~` needs a regex literal, got #{nodename(pat)}") unless pat.is_a?(Prism::RegularExpressionNode)
      ["{ let __s: &str = &#{wrap(recv)}; #{regex_id(pat)}.find(__s).map(|__m| __s[..__m.start()].chars().count() as i64) }",
       :oi64, false]
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
      if struct_list?(OPT.fetch(l[1]))
        bad(node.right, "the default for a nil-able list of objects must be a list of the same kind, got #{r[1]}") unless r[1] == OPT.fetch(l[1])
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
        # Negative literals carry protective parens (for `a - -1`); a single `unwrap_or` argument does not
        # need them, and rustc warns (unused_parens), so strip them as elsewhere.
        pure ? ["#{wrap(l)}.unwrap_or(#{unparen(d)})", want, true] : lazy.call(d, want)
      end
    end

    # Ruby's Float#to_s writes a whole Float with a trailing ".0" (1.0); Rust's Display writes "1".
    # (For |x| >= 1e16 Ruby also switches to scientific notation, which this does not reproduce.)
    def f64_str(rust) = "{ let __s = (#{rust}).to_string(); if !__s.contains('.') && __s.chars().all(|c| c.is_ascii_digit() || c == '-') { __s + \".0\" } else { __s } }"

    # nil.to_s is "" in Ruby.
    def opt_to_s(recv)
      code = if recv[1] == :ostr
               "#{wrap(recv)}.unwrap_or_default()"
             elsif recv[1] == :of64
               "#{wrap(recv)}.map(|__n| #{f64_str('__n')}).unwrap_or_default()"
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

    # obj&.field for a field of an optional nested object. Ruby safe navigation answers nil when the
    # object is nil, so the result is nil-able. The receiver is an owned params field, so as_ref()
    # borrows it and the object can be read again.
    def safe_nav_call(node, env)
      recv = expr(node.receiver, env)
      inner = OPT[recv[1]] or
        bad(node, "`&.` is only for a value that may be nil, but `#{node.receiver.slice}` is always present")
      unless inner.to_s.start_with?("struct:")
        bad(node, "`&.` is only supported on an optional nested object so far, not on #{TypeNames.display(recv[1])}")
      end
      args = node.arguments ? node.arguments.arguments : []
      bad(node, "`&.` on a nested object takes no arguments") unless args.empty?
      name = node.name
      return ["#{wrap(recv)}.is_none()", :bool, true] if name == :nil?

      sname = inner.to_s.delete_prefix("struct:")
      st = (@structs + @outputs).find { |p| p["name"] == sname } or bad(node, "unknown params `#{sname}`")
      f = st["fields"].find { |x| x["name"] == name.to_s } or
        bad(node, "#{sname} has no field `#{name}` (it has: #{st["fields"].map { |x| x["name"] }.join(", ")})", word: name, from: st["fields"].map { |x| x["name"] })
      t = field_type(f)
      copy = %i[i32 i64 f64 bool oi32 oi64 of64 obool].include?(t)
      suffix = copy ? "" : ".clone()"
      if OPT.key?(t)
        ["#{wrap(recv)}.as_ref().and_then(|__o| __o.#{name}.clone())", t, false]
      else
        ["#{wrap(recv)}.as_ref().map(|__o| __o.#{name}#{suffix})", OPT_OF.fetch(t), false]
      end
    end

    # The type a field has inside a body. Lists are lists of strings, integers or floats, a nested object is a
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
    def lower_helper(blk, names, types, ret, kw_params = nil)
      @ret = ret
      @helper = true
      env = {}
      reqs = blk.parameters&.parameters&.requireds || []
      names.each_with_index do |n, i|
        env[n.to_sym] = types[i]
        @declared << [n.to_sym, reqs[i], "parameter"]
        note_decl(reqs[i].location, n.to_sym, "parameter", types[i])
      end
      (kw_params || []).each do |kname, ktype, knode|
        env[kname.to_sym] = ktype.to_sym
        @declared << [kname.to_sym, knode, "parameter"]
        note_decl(name_span(knode, kname), kname.to_sym, "parameter", ktype.to_sym)
      end
      st = blk.body
      bad(blk, "empty helper body") unless st.is_a?(Prism::StatementsNode)
      lets, e, t, = stmts(st, env)
      bad(st, "a helper cannot end in `raise` or `return`; end it in a value") if t == :never
      code = coerce(unparen(e), t, ret) or bad(st, "the helper returns #{ret} but its body ends in #{t}")
      reject_unused
      { "locals" => lets, "expr" => code, "fallible" => @fallible, "uses_async" => @uses_async, "async_reason" => @async_reason }
    end
    public :lower_helper

    # name(args) for a declared helper. Arguments are passed owned (strings and lists are cloned, so the
    # caller can keep using them). A helper that can fail returns a Result: the call propagates it with `?`.
    def helper_call(node, args, env)
      h = @helpers.fetch(node.name.to_s)
      args = args.dup
      kwn = args.last.is_a?(Prism::KeywordHashNode) ? args.pop : nil
      unless args.size == h["args"].size
        bad(node, "helper `#{h['name']}` takes #{h['args'].size} argument(s), got #{args.size}; expected `#{h['name']}(#{h['args'].join(', ')})`")
      end
      parts = args.zip(h["args"]).map do |arg, (pname, ptype)|
        r = expr(arg, env)
        helper_arg(arg, r, ptype.to_sym, h["name"], pname)
      end
      given = {}
      (kwn ? kwn.elements : []).each do |el|
        bad(el, "helper `#{h['name']}`: keyword arguments are written `name: value`") unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
        key = el.key.unescaped
        spec = h["kw"].find { |k| k["name"] == key } or
          bad(el, "helper `#{h['name']}` has no keyword `#{key}:`#{h['kw'].empty? ? '' : " (it has: #{h['kw'].map { |k| k['name'] }.join(', ')})"}", word: key, from: h["kw"].map { |k| k["name"] })
        bad(el, "duplicate `#{key}:`") if given.key?(key)
        given[key] = el.value
      end
      h["kw"].each do |k|
        kname = k["name"]
        if given.key?(kname)
          arg = given.fetch(kname)
          r = expr(arg, env)
          parts << helper_arg(arg, r, k["type"].to_sym, h["name"], kname)
        elsif k["required"]
          bad(node, "helper `#{h['name']}` is missing required keyword `#{kname}:`")
        else
          parts << helper_default_code(k["default"], k["type"].to_sym)
        end
      end
      (@flags["used_helpers"] ||= {})[h["name"]] = true
      call = "helper_#{h['name']}(#{parts.join(', ')})"
      if h["async"]
        refuse_async(node, "helper `#{h['name']}`", h["async_reason"])
        @uses_async = true
        @async_reason ||= "calls helper `#{h['name']}` (line #{node.location.start_line})#{h['async_reason'] ? ", which is async because it #{h['async_reason']}" : ''}"
        call = "#{call}.await"
      end
      return [call, h["returns"].to_sym, true] unless h["body"]["fallible"]

      @fallible = true
      ["#{call}?", h["returns"].to_sym, true]
    end

    # One helper argument: a value of the base type fits a nil-able parameter as Some(value), while a nil-able
    # value fits only a nil-able parameter. An owned value is cloned, because the parameter takes it by value.
    def helper_arg(arg, r, want, hname, pname)
      code = coerce(wrap(r), r[1], want) or bad(arg, "helper `#{hname}`: argument `#{pname}` should be #{want}, got #{r[1]}")
      base = OPT.key?(want) ? OPT.fetch(want) : want
      %i[string strs i64s f64s].include?(base) && r[1] != :str ? "#{code}.clone()" : code
    end

    # Rust for a keyword parameter's default; the reader has already checked it is a literal of the type.
    def helper_default_code(value, want)
      if OPT.key?(want)
        return "None" if value.nil?

        return "Some(#{helper_default_code(value, OPT.fetch(want))})"
      end

      case want
      when :string then "#{RmcpDsl.rstr(value)}.to_string()"
      when :strs then "vec![#{value.map { |v| "#{RmcpDsl.rstr(v)}.to_string()" }.join(', ')}]"
      when :i64s then "vec![#{value.join(', ')}]"
      when :f64s then "vec![#{value.map { |v| v.is_a?(Integer) ? "((#{v}) as f64)" : v.to_s }.join(', ')}]"
      when :f64 then value.is_a?(Integer) ? "((#{value}) as f64)" : value.to_s
      else value.to_s
      end
    end

    def binop(n, op, l, r)
      bad(n, "a secret cannot be compared or combined (`#{op}`): it can only be passed to a binding or rust_fn function") if l[1] == :secret || r[1] == :secret
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

    # Methods on a list of strings (:strs), integers (:i64s) or floats (:f64s). Block methods compile to for loops, not
    # closures, so a block may use checked arithmetic, to_i and raise: they leave the enclosing closure
    # with `?` or `return Err`. A list is only ever borrowed, so a local list can be used again.
    def list_call(node, name, args, recv, env)
      elem = LISTS.fetch(recv[1])
      allowed = LIST_METHODS + (elem == :i64 ? INT_LIST_METHODS : [])
      allowed = (allowed + FLOAT_LIST_METHODS - %i[tally]) if elem == :f64
      unless allowed.include?(name)
        bad(node, "a list of #{{ i64: 'integers', f64: 'floats' }.fetch(elem, 'strings')} only supports #{allowed.join('/')} so far, not `#{name}`",
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
      when :sum then list_sum(node, recv, elem)
      when :min, :max
        if elem == :f64
          ["#{wrap(recv)}.iter().copied().reduce(f64::#{name})", :of64, true]
        else
          ["#{wrap(recv)}.iter().copied().#{name}()", :oi64, true]
        end
      else list_block(node, name, recv, env, elem)
      end
    end

    # A list of another params struct (:"list<struct:Name>"): length/size, empty?, first/last, [], reverse,
    # each, map, select/reject, find, any?/all? and count. first/last/[]/find give a nil-able element
    # (:"opt<struct:Name>"); each and the block methods bind a non-nil :struct:Name. Ordering, equality and
    # stringification (sort, uniq, include?, join, sum, min, max) are refused: an object has none of them.
    def struct_list_call(node, name, args, recv, env)
      unless STRUCT_LIST_METHODS.include?(name)
        bad(node, "a list of #{struct_list_name(recv[1])} only supports #{STRUCT_LIST_METHODS.join("/")} so far, not `#{name}`",
            word: name.to_s, from: STRUCT_LIST_METHODS.map(&:to_s))
      end
      want = LIST_ARITY.fetch(name)
      unless want === args.size
        shape = want.is_a?(Range) ? ".#{name} or .#{name}(arg)" : (want.zero? ? ".#{name}" : ".#{name}(arg)")
        bad(node, "`#{name}` takes #{want.is_a?(Range) ? "at most one argument" : "#{want} argument(s)"}; write `#{shape}`")
      end
      elem = :"struct:#{struct_list_name(recv[1])}"
      opt_elem = OPT_OF.fetch(elem)
      case name
      when :length, :size then ["(#{wrap(recv)}.len() as i64)", :i64, true]
      when :empty? then ["#{wrap(recv)}.is_empty()", :bool, true]
      when :first, :last then ["#{wrap(recv)}.#{name}().cloned()", opt_elem, true]
      when :[] then struct_list_at(recv, args[0], env, opt_elem)
      when :reverse then ["{ let mut __v = #{wrap(recv)}.clone(); __v.reverse(); __v }", recv[1], false]
      when :each then each_expr(node, recv, env)
      else struct_list_block(node, name, recv, env, elem)
      end
    end

    # xs[i] for a list of objects: negative indexes count from the end, out of range is nil, as in Ruby.
    def struct_list_at(recv, arg, env, opt_elem)
      i = expr(arg, env)
      bad(arg, "a list index must be an integer, got #{i[1]}") unless %i[int i32 i64].include?(i[1])
      ["{ let __v = &#{wrap(recv)}; let __n = __v.len() as i64; let __i = #{wrap(i)} as i64; " \
       "let __j = if __i < 0 { __i + __n } else { __i }; " \
       "if __j >= 0 && __j < __n { Some(__v[__j as usize].clone()) } else { None } }", opt_elem, false]
    end

    # map / select / reject / find / any? / all? / count with a block over a list of objects. The block
    # parameter is an owned :struct:Name; map returns a list of strings, integers or floats (list_map).
    def struct_list_block(node, name, recv, env, elem)
      return ["(#{wrap(recv)}.len() as i64)", :i64, true] if name == :count && !node.block

      blk = node.block
      bad(node, "`#{name}` needs a literal { |x| ... } block") unless blk.is_a?(Prism::BlockNode)
      param = block_param(blk, env, "`#{name}`", elem)
      st = blk.body
      bad(blk, "empty #{name} block") unless st.is_a?(Prism::StatementsNode)
      lets, e, t, = stmts(st, env.merge(param => elem))
      value = "{ let #{param} = (*__e).clone(); #{(lets + [unparen(e)]).join(" ")} }"
      src = "for __e in #{wrap(recv)}.iter()"
      return list_map(blk, value, t, src) if name == :map

      bad(blk, "the `#{name}` block must return true or false, got #{t}") unless t == :bool
      ty = elem.to_s.delete_prefix("struct:")
      case name
      when :select, :reject
        test = name == :select ? value : "!#{value}"
        ["{ let mut __out = Vec::<#{ty}>::new(); #{src} { if #{test} { __out.push((*__e).clone()); } } __out }", recv[1], false]
      when :find
        ["{ let mut __r: Option<#{ty}> = None; #{src} { if #{value} { __r = Some((*__e).clone()); break; } } __r }", OPT_OF.fetch(elem), false]
      when :any?
        ["{ let mut __r = false; #{src} { if #{value} { __r = true; break; } } __r }", :bool, false]
      when :all?
        ["{ let mut __r = true; #{src} { if !#{value} { __r = false; break; } } __r }", :bool, false]
      else
        ["{ let mut __r: i64 = 0; #{src} { if #{value} { __r += 1; } } __r }", :i64, false]
      end
    end

    # A list of maps (:"list<map<...>>"), the value `values` gives on a map of maps. It reads like a list of
    # objects: length/size, empty?, first/last, [], reverse, each, map, select/reject, find, any?/all? and
    # count. Ordering, equality and stringification (sort, uniq, include?, join, sum, min, max) are refused:
    # a map has none of them.
    def map_list_call(node, name, args, recv, env)
      unless STRUCT_LIST_METHODS.include?(name)
        bad(node, "a list of maps only supports #{STRUCT_LIST_METHODS.join("/")} so far, not `#{name}`",
            word: name.to_s, from: STRUCT_LIST_METHODS.map(&:to_s))
      end
      want = LIST_ARITY.fetch(name)
      unless want === args.size
        shape = want.is_a?(Range) ? ".#{name} or .#{name}(arg)" : (want.zero? ? ".#{name}" : ".#{name}(arg)")
        bad(node, "`#{name}` takes #{want.is_a?(Range) ? "at most one argument" : "#{want} argument(s)"}; write `#{shape}`")
      end
      elem = CompositeTypes.map_list_value(recv[1])
      opt_elem = OPT_OF.fetch(elem)
      case name
      when :length, :size then ["(#{wrap(recv)}.len() as i64)", :i64, true]
      when :empty? then ["#{wrap(recv)}.is_empty()", :bool, true]
      when :first, :last then ["#{wrap(recv)}.#{name}().cloned()", opt_elem, true]
      when :[] then map_list_at(recv, args[0], env, opt_elem)
      when :reverse then ["{ let mut __v = #{wrap(recv)}.clone(); __v.reverse(); __v }", recv[1], false]
      when :each then each_expr(node, recv, env)
      else map_list_block(node, name, recv, env, elem)
      end
    end

    # xs[i] for a list of maps: negative indexes count from the end, out of range is nil, as in Ruby.
    def map_list_at(recv, arg, env, opt_elem)
      i = expr(arg, env)
      bad(arg, "a list index must be an integer, got #{i[1]}") unless %i[int i32 i64].include?(i[1])
      ["{ let __v = &#{wrap(recv)}; let __n = __v.len() as i64; let __i = #{wrap(i)} as i64; " \
       "let __j = if __i < 0 { __i + __n } else { __i }; " \
       "if __j >= 0 && __j < __n { Some(__v[__j as usize].clone()) } else { None } }", opt_elem, false]
    end

    # map / select / reject / find / any? / all? / count with a block over a list of maps. The block parameter
    # is an owned map; map returns a list of strings, integers or floats (list_map).
    def map_list_block(node, name, recv, env, elem)
      return ["(#{wrap(recv)}.len() as i64)", :i64, true] if name == :count && !node.block

      blk = node.block
      bad(node, "`#{name}` needs a literal { |x| ... } block") unless blk.is_a?(Prism::BlockNode)
      param = block_param(blk, env, "`#{name}`", elem)
      st = blk.body
      bad(blk, "empty #{name} block") unless st.is_a?(Prism::StatementsNode)
      lets, e, t, = stmts(st, env.merge(param => elem))
      value = "{ let #{param} = (*__e).clone(); #{(lets + [unparen(e)]).join(" ")} }"
      src = "for __e in #{wrap(recv)}.iter()"
      return list_map(blk, value, t, src) if name == :map

      bad(blk, "the `#{name}` block must return true or false, got #{TypeNames.display(t)}") unless t == :bool
      case name
      when :select, :reject
        test = name == :select ? value : "!#{value}"
        ["{ let mut __out = Vec::<#{CompositeTypes.map_value_rust(elem)}>::new(); #{src} { if #{test} { __out.push((*__e).clone()); } } __out }", recv[1], false]
      when :find
        ["{ let mut __r: Option<#{CompositeTypes.map_value_rust(elem)}> = None; #{src} { if #{value} { __r = Some((*__e).clone()); break; } } __r }", OPT_OF.fetch(elem), false]
      when :any?
        ["{ let mut __r = false; #{src} { if #{value} { __r = true; break; } } __r }", :bool, false]
      when :all?
        ["{ let mut __r = true; #{src} { if !#{value} { __r = false; break; } } __r }", :bool, false]
      else
        ["{ let mut __r: i64 = 0; #{src} { if #{value} { __r += 1; } } __r }", :i64, false]
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
      ((LISTS.key?(inner) || struct_list?(inner)) && node.is_a?(Prism::ArrayNode) && node.elements.empty?) ||
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
        code = "#{code}.clone()" if vnode.is_a?(Prism::LocalVariableReadNode) && %i[string i64s f64s].include?(value)
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
      when :map, :select, :reject, :each then map_block(node, name, recv, env, value)
      else map_merge(node, recv, args, env)
      end
    end

    # Reads on a nil-able map (the value of a map of maps): m["a"] gives the inner map's value, nil when the
    # outer key is missing, and nil? tells whether the outer key was there. Anything else would need the map
    # itself, so it is refused until the value is branched on.
    def opt_map_call(node, name, args, recv, env, inner)
      value = MAPS.fetch(inner)
      case name
      when :nil?
        bad(node, "`nil?` takes no arguments") unless args.empty?
        ["#{wrap(recv)}.is_none()", :bool, true]
      when :[]
        bad(node, "`[]` takes one argument on a map") unless args.size == 1
        ["#{wrap(recv)}.as_ref().and_then(|__m| __m.get(#{map_key(args[0], env)}).cloned())", OPT_OF.fetch(value), false]
      else
        bad(node, "`#{node.receiver.slice}` may be nil, so index it (`#{node.receiver.slice}[...][...]`) or test `.nil?` first",
            word: name.to_s, from: %w[[] nil?])
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
      if value.to_s.start_with?("struct:") # a map of objects: a list of them
        name = value.to_s.delete_prefix("struct:")
        return ["#{wrap(recv)}.values().cloned().collect::<Vec<#{name}>>()", CompositeTypes.object_list_symbol(name), true]
      end
      if CompositeTypes.scalar_map?(value) # a map of maps: a list of the inner maps
        return ["#{wrap(recv)}.values().cloned().collect::<Vec<#{CompositeTypes.map_value_rust(value)}>>()", CompositeTypes.map_list_symbol(value), true]
      end
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

    # map / select / reject with a block on a map. `map` returns a list of strings or integers
    # (the result of the block decides), exactly like a list `map`; `select` and `reject` return
    # a new map with the same key and value types, built as a BTreeMap. The block takes |k, v|:
    # k is the String key and v the value type. A map is read-only; nothing here changes it.
    def map_block(node, name, recv, env, value)
      return each_expr(node, recv, env) if name == :each
      blk = node.block
      bad(node, "`#{name}` on a map needs a literal { |k, v| ... } block") unless blk.is_a?(Prism::BlockNode)
      kname, vname = map_block_params(blk, env, name, value)
      st = blk.body
      bad(blk, "empty #{name} block") unless st.is_a?(Prism::StatementsNode)
      lets, e, t, = stmts(st, env.merge(kname => :string, vname => value))
      bind = "let #{kname} = __k.to_string(); let #{vname} = #{map_block_value(value)}; "
      body = "{ #{bind}#{(lets + [unparen(e)]).join(", ")} }"
      src = "for (__k, __v) in #{wrap(recv)}.iter()"
      return map_map(blk, body, t, src) if name == :map

      bad(blk, "the `#{name}` block must return true or false, got #{TypeNames.display(t)}") unless t == :bool
      test = name == :select ? body : "!#{body}"
      ["{ let mut __out = #{CompositeTypes.map_rust(value).sub('<String', '::<String')}::new(); #{src} { if #{test} { " \
       "__out.insert(__k.to_string(), (*__v).clone()); } } __out }", recv[1], false]
    end

    # The block binding for a value of the map value type: strings are owned, the Copy scalars
    # copied, and a list cloned.
    def map_block_value(value)
      case value
      when :string then "__v.to_string()"
      when :strs, :i64s, :f64s then "__v.clone()"
      when :i64, :f64, :bool then "*__v"
      else "(*__v).clone()" # a nested object or a nested map
      end
    end

    # The two plain parameters |k, v| of a map block; both must be read (reject_unused enforces it).
    def map_block_params(blk, env, name, value)
      ps = blk.parameters
      good = ps.is_a?(Prism::BlockParametersNode) && ps.locals.empty? && ps.parameters
      good &&= ps.parameters.requireds.size == 2 && ps.parameters.requireds.all? { |r| r.is_a?(Prism::RequiredParameterNode) }
      good &&= [ps.parameters.optionals, ps.parameters.posts, ps.parameters.keywords].all?(&:empty?)
      good &&= !ps.parameters.rest && !ps.parameters.keyword_rest && !ps.parameters.block
      bad(blk, "`#{name}` takes a block with exactly two plain parameters, |k, v|") unless good
      ks, vs = ps.parameters.requireds
      bad(blk, "the block parameters must have different names") if ks.name == vs.name
      [ks, vs].each do |r|
        bad(blk, "`#{r.name}` is already defined") if env.key?(r.name)
        bad(blk, "block parameter `#{r.name}` must be snake_case and not a Rust keyword") if !r.name.to_s.match?(SNAKE) || RUST_KW.include?(r.name.to_s)
        @declared << [r.name, r, "block parameter"]
      end
      note_decl(ks.location, ks.name, "parameter", :string)
      note_decl(vs.location, vs.name, "parameter", value)
      [ks.name, vs.name]
    end

    # map on a map: the result of the block decides whether the list holds strings or integers.
    def map_map(blk, body, type, src)
      kind = if %i[string str].include?(type) then :string
             elsif %i[i32 i64 int].include?(type) then :i64
             end
      bad(blk, "the `map` block must return a string or an integer, got #{TypeNames.display(type)}") unless kind
      push = if kind == :i64 then "#{body} as i64"
             elsif type == :str then "#{body}.to_string()"
             else body
             end
      ["{ let mut __out = Vec::<#{kind == :i64 ? "i64" : "String"}>::new(); #{src} { __out.push(#{push}); } __out }",
       LIST_OF.fetch(kind), false]
    end

    def list_end(name, recv, elem)
      return ["#{wrap(recv)}.#{name}().copied()", :of64, true] if elem == :f64
      return ["#{wrap(recv)}.#{name}().copied()", :oi64, true] if elem == :i64

      ["#{wrap(recv)}.#{name}().map(|__x| __x.to_string())", :ostr, true]
    end

    # xs[i]: negative indexes count from the end, and out of range is nil, as in Ruby.
    def list_at(recv, arg, env, elem)
      i = expr(arg, env)
      bad(arg, "a list index must be an integer, got #{i[1]}") unless %i[int i32 i64].include?(i[1])
      item = %i[i64 f64].include?(elem) ? "__v[__j as usize]" : "__v[__j as usize].to_string()"
      ["{ let __v = &#{wrap(recv)}; let __n = __v.len() as i64; let __i = #{wrap(i)} as i64; " \
       "let __j = if __i < 0 { __i + __n } else { __i }; " \
       "if __j >= 0 && __j < __n { Some(#{item}) } else { None } }", { i64: :oi64, f64: :of64 }.fetch(elem, :ostr), false]
    end

    def list_include(recv, arg, env, elem)
      a = expr(arg, env)
      if elem == :f64
        bad(arg, "`include?` on a list of floats takes a number, got #{a[1]}") unless NUM.include?(a[1])
        value = a[1] == :f64 ? wrap(a) : "#{wrap(a)} as f64"
        return ["{ let __a = #{value}; #{wrap(recv)}.iter().any(|__e| *__e == __a) }", :bool, false]
      end
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
      return ["#{wrap(recv)}.iter().map(|__e| #{f64_str('*__e')}).collect::<Vec<String>>().join(#{lit})", :string, true] if elem == :f64

      ["#{wrap(recv)}.iter().map(|__e| __e.to_string()).collect::<Vec<String>>().join(#{lit})", :string, true]
    end

    # sort (bytewise for strings, like Ruby), uniq (first occurrence wins) and reverse.
    def list_reorder(name, recv, elem)
      if elem == :f64
        code =
          case name
          when :sort then "{ let mut __v: Vec<f64> = #{wrap(recv)}.iter().copied().collect(); __v.sort_by(|__a, __b| __a.total_cmp(__b)); __v }"
          when :reverse then "{ let mut __v: Vec<f64> = #{wrap(recv)}.iter().copied().collect(); __v.reverse(); __v }"
          else "{ let mut __out: Vec<f64> = Vec::new(); for __e in #{wrap(recv)}.iter() { if !__out.contains(__e) { __out.push(*__e); } } __out }"
          end
        return [code, :f64s, false]
      end
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
    def list_sum(node, recv, elem)
      return ["#{wrap(recv)}.iter().copied().sum::<f64>()", :f64, true] if elem == :f64

      @fallible = true
      (@flags["checked"] ||= {})["add:i64"] = true
      ["{ let mut __s: i64 = 0; for __e in #{wrap(recv)}.iter() { __s = ck_add_i64(__s, *__e, " \
       "#{RmcpDsl.rstr(where(node))})?; } __s }", :i64, false]
    end

    # map / select / reject / find / any? / all? / count with a block, as for loops over the borrowed list.
    def list_block(node, name, recv, env, elem)
      return ["(#{wrap(recv)}.len() as i64)", :i64, true] if name == :count && !node.block
      return each_expr(node, recv, env) if name == :each

      blk = node.block
      bad(node, "`#{name}` needs a literal { |x| ... } block") unless blk.is_a?(Prism::BlockNode)
      param = block_param(blk, env, "`#{name}`", elem)
      st = blk.body
      bad(blk, "empty #{name} block") unless st.is_a?(Prism::StatementsNode)
      lets, e, t, = stmts(st, env.merge(param => elem))
      own = %i[i64 f64].include?(elem) ? "*__e" : "__e.to_string()"
      value = "{ let #{param} = #{own}; #{(lets + [unparen(e)]).join(' ')} }"
      src = "for __e in #{wrap(recv)}.iter()"
      return list_map(blk, value, t, src) if name == :map

      bad(blk, "the `#{name}` block must return true or false, got #{t}") unless t == :bool
      ety = { i64: "i64", f64: "f64" }.fetch(elem, "String")
      case name
      when :select, :reject
        test = name == :select ? value : "!#{value}"
        ["{ let mut __out = Vec::<#{ety}>::new(); #{src} { if #{test} { __out.push(#{own}); } } __out }",
         LIST_OF.fetch(elem), false]
      when :find
        ["{ let mut __r: Option<#{ety}> = None; #{src} { if #{value} { __r = Some(#{own}); break; } } __r }",
         { i64: :oi64, f64: :of64 }.fetch(elem, :ostr), false]
      when :any?
        ["{ let mut __r = false; #{src} { if #{value} { __r = true; break; } } __r }", :bool, false]
      when :all?
        ["{ let mut __r = true; #{src} { if !#{value} { __r = false; break; } } __r }", :bool, false]
      else
        ["{ let mut __r: i64 = 0; #{src} { if #{value} { __r += 1; } } __r }", :i64, false]
      end
    end

    # map: a block that returns strings, integers or floats gives a list of that element type.
    def list_map(blk, value, type, src)
      kind = if %i[string str].include?(type) then :string
             elsif %i[i32 i64 int].include?(type) then :i64
             elsif type == :f64 then :f64
             end
      bad(blk, "the `map` block must return a string, an integer or a float, got #{type}") unless kind
      push = if kind == :i64 then "#{value} as i64"
             elsif type == :str then "#{value}.to_string()"
             else value
             end
      ty = { i64: "i64", f64: "f64" }.fetch(kind, "String")
      ["{ let mut __out = Vec::<#{ty}>::new(); #{src} { __out.push(#{push}); } __out }",
       LIST_OF.fetch(kind), false]
    end

    # ["a", "b"] is a list of strings and [1, 2] a list of integers; mixing them is refused.
    def array_lit(node, env)
      bad(node, "an array literal needs at least one element") if node.elements.empty?
      items = node.elements.map { |el| expr(el, env) }
      if items.all? { |e| %i[str string].include?(e[1]) }
        ["vec![#{items.map { |e| e[1] == :str ? "#{e[0]}.to_string()" : e[0] }.join(', ')}]", :strs, true]
      elsif items.all? { |e| NUM.include?(e[1]) } && items.any? { |e| e[1] == :f64 }
        ["vec![#{items.map { |e| e[1] == :f64 ? e[0] : "(#{wrap(e)} as f64)" }.join(', ')}]", :f64s, true]
      elsif items.all? { |e| %i[int i32 i64].include?(e[1]) }
        ["vec![#{items.map { |e| "#{wrap(e)} as i64" }.join(', ')}]", :i64s, true]
      elsif items.all? { |e| e[1] == :block }
        ["vec![#{items.map(&:first).join(', ')}]", :blocks, true]
      elsif items.all? { |e| e[1] == :rcontent }
        ["vec![#{items.map(&:first).join(', ')}]", :rcontents, true]
      else
        bad(node, "array elements must all be strings, all be numbers, all be content blocks or all be resource contents")
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
        ok = (want_t == :string && %i[string str secret].include?(rt)) || rt == want_t ||
             (rt == :int && INTS.include?(want_t))
        bad(arg, "argument of `#{fname}` should be #{want_t}, got #{r[1]}") unless ok
        want_t == :string ? "&#{wrap(r)}" : wrap(r)
      end
      prefix = ext["from"] ? "#{ext["from"]}::" : ""
      call = "#{prefix}#{fname}(#{parts.join(', ')})"
      if ext["async"]
        refuse_async(node, "rust_fn `#{fname}`", ext["async_reason"])
        @uses_async = true
        @async_reason ||= "calls rust_fn `#{fname}` (line #{node.location.start_line})"
        call = "#{call}.await"
      end
      [call, ext["returns"].to_sym, true]
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
    # `text` and `blob` build a resource content (not a tool/prompt content block): a resource body may end
    # in one or an array of them, and they become the contents of the ReadResourceResult.
    RESOURCE_CONTENT = {
      text: { pos: %i[string], kw: { uri: :uri, mime_type: :mime } },
      blob: { pos: %i[data], kw: { uri: :uri, mime_type: :mime } }
    }.freeze

    def resource_body? = @tool.to_s.start_with?("resource ")

    # text(s, uri:, mime_type:) and blob(base64, uri:, mime_type:): one content of a resource read. A literal
    # uri, MIME type or base64 string is checked here; the uri defaults to the uri being read and the MIME type
    # to the resource's `mime_type:` (text keeps text/plain and blob stays none when the resource has none).
    def resource_content_call(node, args, env)
      name = node.name
      shape = RESOURCE_CONTENT.fetch(name)
      kw = args.last.is_a?(Prism::KeywordHashNode) ? args.pop : nil
      unless args.size == shape[:pos].size
        bad(node, "#{name} takes #{shape[:pos].size} positional argument(s) (#{shape[:pos].join(', ')}), got #{args.size}")
      end
      given = content_keywords(node, kw, shape)
      parts = args.zip(shape[:pos]).map { |arg, kind| content_arg(arg, kind, env, name) }
      opts = given.to_h { |key, value| [key, content_arg(value, shape[:kw].fetch(key), env, "#{name} #{key}:")] }
      @used_read_uri = true unless opts[:uri]
      uri = opts[:uri] || "uri"
      mime = if opts[:mime_type]
               ".with_mime_type(#{opts[:mime_type]})"
             elsif @mime_type
               ".with_mime_type(#{RmcpDsl.rstr(@mime_type)})"
             else
               ""
             end
      ["rmcp::model::ResourceContents::#{name}(#{parts[0]}, #{uri})#{mime}", :rcontent, true]
    end

    def content_call(node, args, env)

      name = node.name
      unless @tool.to_s.start_with?("tool ", "prompt ")
        bad(node, "`#{name}` builds a content block, which only a tool body or a prompt message can return (a resource body returns a string, text(...) or blob(...))")
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

    # setting(:name): the value of a server setting, read from the environment when the server started. A required
    # setting is a string, an optional one a nil-able string, and a secret has the type :secret, which only a binding or
    # rust_fn function may take (see the checks where a string is expected).
    def setting_call(node, args)
      bad(node, "setting(:name) takes the name of a setting declared with `setting :name, env: \"...\"`") unless args.size == 1 && args[0].is_a?(Prism::SymbolNode)
      unless @tool.to_s.start_with?("tool ", "prompt ", "resource ")
        bad(node, "settings are read in a tool, prompt or resource body, not in a helper or a binding")
      end
      name = args[0].unescaped
      declared = @flags["settings"] || {}
      entry = declared[name] or
        bad(args[0], "no setting `#{name}` is declared#{declared.empty? ? '' : " (declared: #{declared.keys.join(', ')})"}; add `setting :#{name}, env: \"...\"` to the server",
            word: name, from: declared.keys)
      (@flags["used_settings"] ||= {})[name] = true
      type = entry["secret"] ? :secret : (entry["optional"] ? :ostr : :string)
      ["settings().#{name}.clone()", type, true]
    end

    # `progress` as a statement in a tool body: report how far along the call is. Only a tool body may send
    # one, and only when the client supplied a progress token (per MCP). It makes the tool fn async and it
    # can fail, so the body is wrapped in a Result closure like `raise` does.
    def progress_stmt(node, env)
      unless @tool.to_s.start_with?("tool ")
        place = @tool ? "a #{@tool} body" : "a binding"
        bad(node, "`progress` sends a progress notification, which only a tool body can do, not #{place}")
      end
      bad(node, "progress does not take a block") if node.block
      args = node.arguments ? node.arguments.arguments : []
      kw = args.last.is_a?(Prism::KeywordHashNode) ? args.pop : nil
      bad(node, "progress takes one value argument, such as progress(1, total: 10)") unless args.size == 1
      @uses_context = true
      @uses_async = true
      @async_reason ||= "sends a progress notification"
      @fallible = true
      value = progress_number(args[0], env, "progress value")
      given = content_keywords(node, kw, PROGRESS_SHAPE)
      total = given[:total] && progress_number(given[:total], env, "progress total:")
      message = given[:message] && progress_message(given[:message], env)
      call = +"rmcp::model::ProgressNotificationParam::new(__token, #{value})"
      call << ".with_total(#{total})" if total
      call << ".with_message(#{message})" if message
      ["if let Some(__token) = __ctx.meta.get_progress_token() {",
       "    __ctx.peer.notify_progress(#{call}).await.map_err(|e| format!(\"progress notification failed: {e}\"))?;",
       "}"]
    end

    # Is this node a bare `hide_tool(...)`/`show_tool(...)` call, which only a statement position allows?
    def tool_visibility_call?(node)
      node.is_a?(Prism::CallNode) && node.receiver.nil? && TOOL_VISIBILITY_BUILTINS.key?(node.name)
    end

    # `hide_tool(:name)` / `show_tool(:name)` as a statement in a tool body: change which tools the server
    # advertises. Only a tool body may, the name must be one of the tools this server compiles (the reader
    # checks it once the whole file is read), and clients are told with notifications/tools/list_changed, so
    # the tool fn is async and can fail like `progress`.
    def tool_visibility_stmt(node)
      unless @tool.to_s.start_with?("tool ")
        place = @tool ? "a #{@tool} body" : "a binding"
        bad(node, "`#{node.name}` hides or shows a tool, which only a tool body can do, not #{place}")
      end
      bad(node, "`#{node.name}` does not take a block") if node.block
      args = node.arguments ? node.arguments.arguments : []
      bad(node, "`#{node.name}` takes one tool name, such as #{node.name}(:my_tool)") unless args.size == 1
      name_node = args[0]
      name =
        case name_node
        when Prism::SymbolNode, Prism::StringNode then name_node.unescaped
        else bad(name_node, "`#{node.name}` takes a symbol or string literal tool name, got #{nodename(name_node)}")
        end
      (@flags["tool_visibility_refs"] ||= []) << { "name" => name, "node" => name_node, "builtin" => node.name.to_s }
      @uses_tool_visibility = true
      @uses_context = true
      @uses_async = true
      @async_reason ||= "hides or shows a tool"
      @fallible = true
      ["set_tool_hidden(#{RmcpDsl.rstr(name)}, #{TOOL_VISIBILITY_BUILTINS.fetch(node.name) ? "true" : "false"});",
       "__ctx.peer.notify_tool_list_changed().await.map_err(|e| format!(\"tools/list_changed notification failed: {e}\"))?;"]
    end

    # `log(level, message)` as a statement in a tool body: emit one MCP logging notification
    # (`notifications/message`). It is gated by `feature :logging`, only a tool body may send one, and it
    # makes the tool fn async and fallible like `progress`. SEP-2577 deprecates logging, so the emitted
    # call carries its own `#[allow(deprecated)]` (the generated crate stays warning-free).
    def log_stmt(node, env)
      bad(node, "declare `feature :logging` to use `log`") unless @flags.dig("features", "logging")
      unless @tool.to_s.start_with?("tool ")
        place = @tool ? "a #{@tool} body" : "a binding"
        bad(node, "`log` sends a logging notification, which only a tool body can do, not #{place}")
      end
      bad(node, "log does not take a block") if node.block
      args = node.arguments ? node.arguments.arguments : []
      bad(node, "log takes a level and a message: log(:info, \"message\")") unless args.size == 2
      level = log_level(args[0])
      message = log_message(args[1], env)
      @uses_context = true
      @uses_async = true
      @async_reason ||= "sends a log message"
      @fallible = true
      ["#[allow(deprecated)]",
       "__ctx.peer.notify_logging_message(rmcp::model::LoggingMessageNotificationParam::new(rmcp::model::LoggingLevel::#{level}, rmcp::serde_json::Value::String(#{message}))).await.map_err(|e| format!(\"logging notification failed: {e}\"))?;"]
    end

    # Is this node a bare `log(...)` call, which only a statement position allows?
    def log_call?(node)
      node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name == :log
    end

    # The level argument: a symbol or string literal naming one of the MCP logging levels.
    def log_level(node)
      name = case node
             when Prism::SymbolNode, Prism::StringNode then node.unescaped
             else bad(node, "log's level must be a symbol or string literal such as :info, got #{nodename(node)}")
             end
      LOG_LEVELS.fetch(name.to_sym) do
        bad(node, "`#{name}` is not an MCP logging level (use one of #{LOG_LEVELS.keys.join(', ')})",
            word: name, from: LOG_LEVELS.keys.map(&:to_s))
      end
    end

    def log_message(node, env)
      e = expr(node, env)
      bad(node, "log's message must be a string, got #{TypeNames.display(e[1])}") unless %i[str string].include?(e[1])
      e[1] == :str ? "#{e[0]}.to_string()" : "#{e[0]}.clone()"
    end

    # Is this node a bare `progress(...)` call, which only a statement position allows?
    def progress_call?(node)
      node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name == :progress
    end

    def progress_number(node, env, what)
      e = expr(node, env)
      bad(node, "#{what} must be a number, got #{TypeNames.display(e[1])}") unless NUM.include?(e[1])
      e[1] == :f64 ? e[0] : "#{wrap(e)} as f64"
    end

    def progress_message(node, env)
      e = expr(node, env)
      bad(node, "progress message must be a string, got #{TypeNames.display(e[1])}") unless %i[str string].include?(e[1])
      e[1] == :str ? "#{e[0]}.to_string()" : e[0]
    end

    # `elicit(message, schema: {...})` in a tool body: ask the client for input and read its answer. It is a
    # server-to-client request, so the tool fn becomes async and needs the request context; a failed call is an
    # error result (`@fallible`). The value has `.action` ("accept", "decline" or "cancel") and `.content`
    # (the client's JSON value, nil when it sent none), read with the same field syntax as a struct.
    def elicit_call(node, args, env)
      unless @tool.to_s.start_with?("tool ")
        place = @tool ? "a #{@tool} body" : "a binding"
        bad(node, "`elicit` asks the client for input, which only a tool body can do, not #{place}")
      end
      kw = args.last.is_a?(Prism::KeywordHashNode) ? args.pop : nil
      bad(node, "elicit takes one argument, the message: elicit(\"What is your name?\", schema: { ... })") unless args.size == 1
      given = content_keywords(node, kw, ELICIT_SHAPE)
      message = elicit_message(args[0], env)
      schema = JsonLiteral.rust(elicit_schema(given[:schema]))
      @uses_context = true
      @uses_async = true
      @async_reason ||= "elicits input from the client"
      @fallible = true
      @uses_elicit = true
      request = "rmcp::model::ElicitRequestParams::FormElicitationParams { meta: None, message: #{message}, " \
                "requested_schema: rmcp::serde_json::from_value::<rmcp::model::ElicitationSchema>(rmcp::serde_json::json!(#{schema}))" \
                ".map_err(|e| format!(\"elicitation schema is not valid: {e}\"))? }"
      rust = <<~RS
        {
            let __elicit = __ctx.peer.create_elicitation(#{request}).await.map_err(|e| format!("elicitation failed: {e}"))?;
            (
                match __elicit.action { rmcp::model::ElicitationAction::Accept => "accept", rmcp::model::ElicitationAction::Decline => "decline", rmcp::model::ElicitationAction::Cancel => "cancel", _ => "unknown" }.to_string(),
                __elicit.content,
            )
        }
      RS
      [rust.chomp, :elicit_result, false]
    end

    def elicit_message(node, env)
      e = expr(node, env)
      bad(node, "elicit's message must be a string, got #{TypeNames.display(e[1])}") unless %i[str string].include?(e[1])
      e[1] == :str ? "#{e[0]}.to_string()" : "#{e[0]}.clone()"
    end

    def elicit_schema(node)
      bad(node, "the elicitation `schema:` must be a JSON object literal, such as { \"type\" => \"object\", \"properties\" => { ... } }, got #{nodename(node)}") unless node.is_a?(Prism::HashNode)
      JsonLiteral.object(node, self, what: "the elicitation `schema:`")
    end

    # `answer.action` and `answer.content` on what elicit returned (a Rust tuple, not a named struct).
    def elicit_field(node, name, recv)
      case name
      when :action then ["#{wrap(recv)}.0.clone()", :string, true]
      when :content then ["#{wrap(recv)}.1.clone()", :ojson, true]
      else
        bad(node, "an elicitation result has `action` and `content`, not `#{name}`", word: name, from: %w[action content])
      end
    end

    # `roots()` in a tool body: ask the client for its roots (`roots/list`) and read the result. A
    # server-to-client request, so the tool fn becomes async and needs the request context; a failed
    # request (a client that did not declare the roots capability, say) is a normal error result
    # (@fallible). Gated by `feature :roots`; SEP-2577 deprecates `list_roots`, so the emitted call
    # carries its own `#[allow(deprecated)]` on the `let` statement (the crate stays warning-free).
    def roots_call(node, args, env)
      bad(node, "declare `feature :roots` to use `roots`") unless @flags.dig("features", "roots")
      unless @tool.to_s.start_with?("tool ")
        place = @tool ? "a #{@tool} body" : "a binding"
        bad(node, "`roots` asks the client for its roots, which only a tool body can do, not #{place}")
      end
      bad(node, "roots takes no arguments; write `roots()`") unless args.empty?
      @uses_context = true
      @uses_async = true
      @async_reason ||= "asks the client for its roots"
      @fallible = true
      ["{ #[allow(deprecated)] let __roots = __ctx.peer.list_roots().await.map_err(|e| format!(\"roots/list failed: {e}\"))?; __roots.roots }",
       :roots_result, false]
    end

    # Methods on the value `roots()` returns (a Vec<Root>): `length`/`size` and `empty?` read the list;
    # `each` and `map` iterate it, and each block parameter is a Root whose `uri` and nil-able `name` are
    # read with the usual struct-field syntax.
    def roots_method(node, name, args, recv, env)
      case name
      when :length, :size
        bad(node, "`#{name}` takes no arguments") unless args.empty?
        ["(#{wrap(recv)}.len() as i64)", :i64, true]
      when :empty?
        bad(node, "`empty?` takes no arguments") unless args.empty?
        ["#{wrap(recv)}.is_empty()", :bool, true]
      when :each
        each_expr(node, recv, env)
      when :map
        map_roots(node, recv, env)
      else
        bad(node, "`roots` is a list of roots; it supports length/size, empty?, each and map, not `#{name}`",
            word: name.to_s, from: %w[length size empty? each map])
      end
    end

    # `roots().map { |root| ... }`: a list of strings or integers, exactly like a list map.
    def map_roots(node, recv, env)
      blk = node.block
      bad(node, "`map` needs a literal { |root| ... } block") unless blk.is_a?(Prism::BlockNode)
      param = block_param(blk, env, "`map`", ROOT_TYPE)
      st = blk.body
      bad(blk, "empty map block") unless st.is_a?(Prism::StatementsNode)
      lets, e, t, = stmts(st, env.merge(param => ROOT_TYPE))
      value = "{ let #{param} = (*__e).clone(); #{(lets + [unparen(e)]).join(' ')} }"
      list_map(blk, value, t, "for __e in #{wrap(recv)}.iter()")
    end

    # `sample(prompt, max_tokens:, system:, temperature:, stop:)` in a tool body: ask the client for an LLM
    # completion (`sampling/createMessage`) and read its reply. A server-to-client request, so the tool fn
    # becomes async and needs the request context; a failed request (a client that did not declare the
    # sampling capability, say) is a normal error result (@fallible). Gated by `feature :sampling`; SEP-2577
    # deprecates sampling, so the emitted call carries its own scoped `#[allow(deprecated)]`.
    def sample_call(node, args, env)
      bad(node, "declare `feature :sampling` to use `sample`") unless @flags.dig("features", "sampling")
      unless @tool.to_s.start_with?("tool ")
        place = @tool ? "a #{@tool} body" : "a binding"
        bad(node, "`sample` asks the client for an LLM completion, which only a tool body can do, not #{place}")
      end
      kw = args.last.is_a?(Prism::KeywordHashNode) ? args.pop : nil
      bad(node, "sample takes one argument, the prompt: sample(\"hello\", max_tokens: 64)") unless args.size == 1
      given = content_keywords(node, kw, SAMPLE_SHAPE)
      prompt = sample_text(args[0], env, "sample's prompt")
      request = "rmcp::model::CreateMessageRequestParams::new(vec![rmcp::model::SamplingMessage::new(" \
                "rmcp::model::Role::User, rmcp::model::SamplingMessageContentBlock::text(#{prompt}))], " \
                "#{sample_int(given.fetch(:max_tokens), env)})"
      request += ".with_system_prompt(#{sample_text(given[:system], env, "sample system:")})" if given[:system]
      request += ".with_temperature(#{sample_temperature(given[:temperature], env)})" if given[:temperature]
      request += ".with_stop_sequences(#{sample_stop(given[:stop], env)})" if given[:stop]
      @uses_context = true
      @uses_async = true
      @async_reason ||= "asks the client's LLM for a completion"
      @fallible = true
      rust = <<~RS
        {
            #[allow(deprecated)]
            let (__sample_text, __sample_model, __sample_stop, __sample_role) = {
                let __sample = __ctx.peer.create_message(#{request}).await.map_err(|e| format!("sampling/createMessage failed: {e}"))?;
                // Bind the tuple first: the content iterator is a temporary that borrows __sample,
                // so as a tail expression it would outlive it (E0597).
                let __sampled = (
                    __sample.message.content.iter().find_map(|b| b.as_text().map(|t| t.text.clone())),
                    __sample.model.clone(),
                    __sample.stop_reason.clone(),
                    match __sample.message.role { rmcp::model::Role::User => "user", rmcp::model::Role::Assistant => "assistant" }.to_string(),
                );
                __sampled
            };
            #[allow(dead_code)]
            struct __SampleResult { text: Option<String>, model: String, stop_reason: Option<String>, role: String }
            __SampleResult { text: __sample_text, model: __sample_model, stop_reason: __sample_stop, role: __sample_role }
        }
      RS
      [rust.chomp, SAMPLE_TYPE, false]
    end

    # A string argument of `sample`: a literal is promoted to String; an expression is cloned.
    def sample_text(node, env, what)
      e = expr(node, env)
      bad(node, "#{what} must be a string, got #{TypeNames.display(e[1])}") unless %i[str string].include?(e[1])
      e[1] == :str ? "#{e[0]}.to_string()" : "#{e[0]}.clone()"
    end

    # max_tokens: is the required u32 token budget; an integer expression is cast.
    def sample_int(node, env)
      e = expr(node, env)
      bad(node, "sample's max_tokens: must be an integer, got #{TypeNames.display(e[1])}") unless %i[int i32 i64].include?(e[1])
      "#{wrap(e)} as u32"
    end

    # temperature: is the optional generation temperature; a number expression is cast to f32.
    def sample_temperature(node, env)
      e = expr(node, env)
      bad(node, "sample's temperature: must be a number, got #{TypeNames.display(e[1])}") unless NUM.include?(e[1])
      "#{wrap(e)} as f32"
    end

    # stop: is the optional list of stop sequences, an array literal of string expressions.
    def sample_stop(node, env)
      bad(node, "sample's stop: must be a list of strings, such as [\"STOP\"]") unless node.is_a?(Prism::ArrayNode)
      seqs = node.elements.map { |el| sample_text(el, env, "each stop sequence") }
      "vec![#{seqs.join(', ')}]"
    end

    # client_name, request_id, cancelled? and the rest of CONTEXT_BUILTINS: a value the MCP request carries.
    # Only a tool body may read one; the generated tool fn then takes a `RequestContext` parameter (Emit#tool_fn).
    def context_call(node, name, args)

      bad(node, "`#{name}` takes no arguments") unless args.empty?
      unless @tool.to_s.start_with?("tool ")
        place = @tool ? "a #{@tool} body" : "a binding"
        bad(node, "`#{name}` reads the request context, which only a tool body can do, not #{place}")
      end
      @uses_context = true
      code, type = CONTEXT_BUILTINS.fetch(name)
      [code, type, true]
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
        ok = (ptype == :string && %i[string str secret].include?(rt)) || rt == ptype || (rt == :int && INTS.include?(ptype))
        bad(arg, "#{file.module_name}.#{fn.name}: argument `#{pname}` should be #{TypeNames.display(ptype)}, got #{TypeNames.display(rt)}") unless ok
        %i[string strs i64s].include?(ptype) || opaque?(ptype) ? "&#{wrap(r)}" : wrap(r)
      end
      (@flags["used_bindings"] ||= {})["#{file.module_name}.#{fn.name}"] = true
      call = "#{file.wrapper(fn)}(#{parts.join(', ')})"
      if fn.async
        refuse_async(node, "#{file.module_name}.#{fn.name}", "is declared `async: true`")
        @uses_async = true
        @async_reason ||= "calls `#{file.module_name}.#{fn.name}` (line #{node.location.start_line}), which is declared async"
        call = "#{call}.await"
      end
      [call, fn.returns, true]
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
      { "locals" => lets, "expr" => e, "fallible" => @fallible, "uses_async" => @uses_async, "async_reason" => @async_reason }
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

    # An async function may only be awaited where there is an async context: a tool, helper, prompt or
    # resource body. A binding compiled from Ruby, or a `complete` block, has no async context (its
    # emitted code is a plain closure), so a call there is refused with the reason the callee is async.
    def async_context?
      @tool.to_s.start_with?("tool ", "helper ", "prompt ", "resource ")
    end

    def refuse_async(node, what, reason)
      return if async_context?

      place = @tool ? "a #{@tool}" : "a binding body"
      chain = reason ? ", which is async because it #{reason}" : ""
      bad(node, "#{what} is async#{chain}; an async call needs a tool, helper, prompt or resource body, not #{place}")
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
      outer_async = @uses_async
      @uses_async = false
      lets, e, t, = stmts(st, env.merge(param => :string))
      e = unparen(e)
      if @fallible
        bad(blk, "integer arithmetic, `to_i`, `raise` or `return` inside a #{name} block is not supported yet; do it outside the block")
      end
      if @uses_async
        bad(blk, "an async call inside a #{name} block is not supported: the block becomes a plain Rust closure, " \
                 "where `.await` is not allowed; do the async call before the substitution")
      end
      @fallible = outer
      @uses_async = outer_async
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

