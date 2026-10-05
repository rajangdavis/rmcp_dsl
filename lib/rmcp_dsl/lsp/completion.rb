# frozen_string_literal: true

module RmcpDsl
  module Lsp
    # Completion for DSL files. Pure: `Completion.at(analysis, line0, utf16_col)` returns LSP CompletionItem
    # hashes (string keys). The line being typed rarely compiles, so the context is decided from the text
    # before the cursor (a block stack built from do/end lines, then the call being typed on the line), and the
    # compiler's types are only a bonus for the receiver of a `.`.
    module Completion
      KIND = { method: 2, function: 3, property: 10, field: 5, variable: 6, value: 12, keyword: 14, snippet: 15 }.freeze
      SNIPPET = 2

      # A method callable in a body: ret is a type, :self, :elem, [:opt, :elem] or :unknown.
      Meth = Struct.new(:name, :ret, :arity, :block, keyword_init: true)

      # Value types, written as the compiler's internal symbols; [:opt, T] is nil-able, [:obj, "Name"] an object.
      INTS = %i[i32 i64 int].freeze
      DISPLAY = { string: "String", i32: "Integer (i32)", i64: "Integer (i64)", int: "Integer", f64: "Float",
                  bool: "T::Boolean", strs: "T::Array[String]", i64s: "T::Array[Integer (i64)]", untyped: "T.untyped" }.freeze
      PARSE = DISPLAY.invert.merge("String" => :string).freeze

      STRING_METHODS = {
        "to_s" => [:string, "0"], "upcase" => [:string, "0"], "downcase" => [:string, "0"], "strip" => [:string, "0"],
        "capitalize" => [:string, "0"], "reverse" => [:string, "0"], "squeeze" => [:string, "0..1"],
        "gsub" => [:string, "2"], "sub" => [:string, "2"], "tr" => [:string, "2"], "delete" => [:string, "1"],
        "split" => [:strs, "0..2"], "chars" => [:strs, "0"], "lines" => [:strs, "0"], "partition" => [:strs, "1"],
        "length" => [:int, "0"], "size" => [:int, "0"], "index" => [[:opt, :int], "1"], "to_i" => [:int, "0"],
        "start_with?" => [:bool, "1"], "end_with?" => [:bool, "1"], "include?" => [:bool, "1"],
        "match?" => [:bool, "1"], "empty?" => [:bool, "0"], "[]" => [[:opt, :string], "1..2"]
      }.freeze
      INT_METHODS = { "to_s" => [:string, "0"], "times" => [:i64s, "0", true], "upto" => [:i64s, "1", true],
                      "downto" => [:i64s, "1", true] }.freeze
      LIST_RET = { "length" => :int, "size" => :int, "count" => :int, "empty?" => :bool, "include?" => :bool,
                   "any?" => :bool, "all?" => :bool, "first" => [:opt, :elem], "last" => [:opt, :elem],
                   "find" => [:opt, :elem], "min" => [:opt, :elem], "max" => [:opt, :elem], "[]" => [:opt, :elem],
                   "sum" => :elem, "join" => :string, "map" => :unknown, "sort" => :self, "uniq" => :self,
                   "reverse" => :self, "to_a" => :self, "select" => :self, "reject" => :self,
                   "tally" => [:map, :i64] }.freeze
      LIST_BLOCKS = %w[map select reject find any? all? count].freeze
      KEYWORDS = %w[if unless else elsif end case when raise return true false nil].freeze

      DOCS = {
        "server" => "The server: name, version and everything it offers", "params" => "A struct of tool arguments",
        "output" => "A structured result a tool may build", "field" => "One field of a params or output struct",
        "tool" => "A tool the server offers", "helper" => "A typed function that bodies can call",
        "prompt" => "A prompt the server offers", "resource" => "A resource the server offers",
        "body" => "The Ruby-subset body that computes the result", "message" => "One message of a prompt conversation",
        "transport" => "How the server talks: :stdio or :http"
      }.freeze

      module_function

      def at(analysis, line0, utf16_col)
        Query.new(analysis, line0, utf16_col).items
      rescue StandardError
        []
      end

      def type_of_display(text)
        s = text.to_s
        return PARSE.fetch(s) if PARSE.key?(s)

        if (m = s.match(/\AT\.nilable\((.*)\)\z/m))
          inner = type_of_display(m[1])
          return inner == :unknown ? :unknown : [:opt, inner]
        end
        if (m = s.match(/\AT::Hash\[String, (.*)\]\z/m))
          value = PARSE[m[1]]
          return map_value?(value) ? [:map, value] : :unknown
        end
        s.match?(/\A[A-Z]\w*\z/) && s != "Regexp" ? [:obj, s] : :unknown
      end

      def display(type)
        case type
        when Array
          case type[0]
          when :opt then "T.nilable(#{display(type[1])})"
          when :map then "T::Hash[String, #{display(type[1])}]"
          else type[1]
          end
        when :unknown then "unknown"
        else DISPLAY.fetch(type) { type.to_s }
        end
      end

      def element(list) = list == :strs ? :string : :i64

      # The methods of one type; objects have fields, not methods (see Query#field_items).
      def methods_for(type)
        case type
        when :string then table(STRING_METHODS)
        when :strs, :i64s then list_methods(type)
        when :i32, :i64, :int then table(INT_METHODS)
        when :f64, :bool then table("to_s" => [:string, "0"])
        when Array then array_methods(type)
        else []
        end
      end

      # The value types a map can hold, as completion names them (the compiler's CompositeTypes::VALUES), and T.untyped
      # for the empty literal.
      def map_value?(value) = value == :untyped || CompositeTypes::VALUES.values.any? { |sym, _| sym == value }

      def array_methods(type)
        case type[0]
        when :opt then type[1].is_a?(Array) && type[1][0] == :map ? table("nil?" => [:bool, "0"]) : table("nil?" => [:bool, "0"], "to_s" => [:string, "0"])
        when :map then map_methods(type[1])
        else []
        end
      end

      # The methods of a map with value type `value`, from Body::MAP_ARITY so the list cannot drift from the compiler.
      def map_methods(value)
        rets = { :[] => [:opt, value], :fetch => value, :keys => :strs, :size => :i64, :length => :i64, :merge => :self,
                 :values => { string: :strs, i64: :i64s }.fetch(value, :unknown) }
        Body::MAP_ARITY.map do |name, arity|
          ret = rets.fetch(name) { name.to_s.end_with?("?") ? :bool : :unknown }
          ret = :unknown if value == :untyped && %i[[] fetch].include?(name)
          Meth.new(name: name.to_s, ret: ret, arity: arity.to_s, block: false)
        end
      end

      def table(hash)
        hash.map { |name, (ret, arity, block)| Meth.new(name: name, ret: ret, arity: arity, block: block || false) }
      end

      def list_methods(type)
        LIST_RET.filter_map do |name, ret|
          next if Body::INT_LIST_METHODS.map(&:to_s).include?(name) && type == :strs
          next if name == "tally" && type == :i64s

          arity = Body::LIST_ARITY[name.to_sym]
          Meth.new(name: name, ret: ret, arity: arity.to_s, block: LIST_BLOCKS.include?(name))
        end
      end

      # The type a call returns on a receiver of `type`; :unknown when it is not a known method.
      def result_of(type, name)
        meth = methods_for(type).find { |m| m.name == name } or return :unknown
        resolve(meth.ret, type)
      end

      def resolve(ret, recv)
        elem = %i[strs i64s].include?(recv) ? element(recv) : :unknown
        case ret
        when :self then recv
        when :elem then elem
        when Array then ret[1] == :elem ? [:opt, elem] : ret
        else ret
        end
      end

      # One completion request: everything is decided from the text above the cursor and the line before it.
      class Query
        BODY_KINDS = %i[body message helper].freeze
        OWNERS = %i[tool prompt resource].freeze
        HEADS = %w[server params output tool helper prompt resource body message].freeze
        BODY_HEAD = /\A\s*(body|message\b[^|]*|helper\b[^|]*)\s+do\s*\|([^|]*)\z/
        FIELD_DECL = /\A\s*field\s+:(\w+)\s*,\s*(:\w+|(?:map|list)\((?:[^()]|\((?:[^()])*\))*\))(.*)\z/
        LEADING_OPENERS = /\A\s*(?:if|unless|while|until|case|begin|def|class|module)\b/

        def initialize(analysis, line0, utf16_col)
          @a = analysis
          line0 = [line0.to_i, 0].max
          @line = line0 + 1
          text = analysis.line_text(@line).dup.force_encoding(Encoding::UTF_8)
          bytecol = Position.from_lsp(text, utf16_col.to_i)
          @prefix = text.byteslice(0, bytecol - 1).to_s.force_encoding(Encoding::UTF_8).scrub
          @above = analysis.lines.first(line0).map { |l| l.dup.force_encoding(Encoding::UTF_8).scrub }
          @stack = scan_stack
          @decls = scan_decls
          @helpers = scan_helpers
        end

        def items
          choices = choice_items and return choices
          return [] if in_string_or_comment?

          if (m = @prefix.match(/(&?\.)([\w?!]*)\z/)) && !@prefix.match?(/\.\.[\w?!]*\z/) && body_entry
            return filter(dot_items(m), m[2])
          end
          return pipe_items if @prefix.match?(/\b(?:do|\{)\s*\|[^|]*\z/)
          return body_items if body_entry

          dsl_items
        end

        private

        # --- text helpers ---------------------------------------------------------------------------------

        def clean(line) = line.gsub(/"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'/, '""').sub(/#.*\z/, "")

        def in_string_or_comment?
          without = @prefix.gsub(/"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'/, "0")
          without.include?("#") || without.match?(/["']/)
        end

        def filter(list, typed)
          return list if typed.to_s.empty?

          t = typed.downcase
          hits = list.select { |i| (i["filterText"] || i["label"]).downcase.start_with?(t) }
          hits.empty? ? list.select { |i| (i["filterText"] || i["label"]).downcase.include?(t) } : hits
        end

        def item(label, kind, detail, doc: nil, insert: nil, snippet: false, sort: "1", filter: nil)
          h = { "label" => label, "kind" => KIND.fetch(kind), "detail" => detail, "sortText" => "#{sort}#{label}" }
          h["documentation"] = doc if doc
          h["insertText"] = insert if insert
          h["insertTextFormat"] = SNIPPET if snippet
          h["filterText"] = filter if filter
          h
        end

        # --- block stack ----------------------------------------------------------------------------------

        # The do-blocks open above the cursor, outermost first: {kind:, line:, text:, params:}. kind is the DSL
        # call that opened it, or :block / :other for anything else.
        def scan_stack
          stack = []
          @above.each_with_index do |raw, idx|
            s = clean(raw)
            stack << { kind: :other, line: idx, text: raw, params: nil } if s.match?(LEADING_OPENERS) || s.match?(/[=(]\s*(?:if|unless|case)\b/)
            s.scan(/\b(do|end)\b(?:\s*\|([^|]*)\|)?/) do |word, params|
              if word == "end"
                stack.pop
              else
                head = s[/\A\s*(\w+)\b(?!:)/, 1]
                kind = HEADS.include?(head) ? head.to_sym : :block
                stack << { kind: kind, line: idx, text: raw, params: params }
              end
            end
          end
          stack
        end

        # The body (or message, or helper) the cursor is in: from the stack, or a one-line `body do |x| ...`.
        def body_entry
          return @body_entry if defined?(@body_entry)

          @body_entry = @stack.reverse.find { |e| BODY_KINDS.include?(e[:kind]) } ||
                        (@prefix.match?(/\A\s*(?:body|message\b[^|]*|helper\b[^|]*)\s+do\s*\|[^|]*\|/) ? { kind: :inline, line: @above.size, text: @prefix, params: nil } : nil)
        end

        def owner_entry = @stack.reverse.find { |e| OWNERS.include?(e[:kind]) }

        # --- declarations ---------------------------------------------------------------------------------

        def scan_decls
          decls = { "params" => {}, "output" => {} }
          current = nil
          @above.each do |raw|
            if (m = raw.match(/\A\s*(params|output)\s+:([A-Z]\w*)\b.*\bdo\b/))
              current = decls[m[1]][m[2]] = []
            elsif current && raw.match?(/\A\s*end\b/)
              current = nil
            elsif current && (m = raw.match(FIELD_DECL))
              current << { name: m[1], type: canonical_type(m[2]), optional: m[3].match?(/optional:\s*true/),
                           doc: m[3][/description:\s*"((?:\\.|[^"\\])*)"/, 1] }
            end
          end
          decls
        end

        # `:string`, `list(:i64)` and `map(list(:string))` as the compiler's canonical field type: "string", "i64_list", "map(string_list)".
        def canonical_type(text)
          inner = text.strip
          if (m = inner.match(/\Amap\(\s*(.*?)\s*\)\z/m))
            "map(#{canonical_type(m[1])})"
          elsif (m = inner.match(/\Alist\(\s*:(\w+)\s*\)\z/))
            "#{m[1]}_list"
          else
            inner.delete_prefix(":")
          end
        end

        def scan_helpers
          @above.each_with_object({}) do |raw, out|
            m = raw.match(/\A\s*helper\s+:(\w+)\s*,\s*args:\s*\[([^\]]*)\]\s*,\s*returns:\s*:(\w+\??)/) or next
            out[m[1]] = { args: m[2].scan(/:(\w+\??)/).flatten, ret: helper_type(m[3]) }
          end
        end

        def fields_of(name) = @decls["params"][name] || @decls["output"][name] || []

        def field_type(f)
          base = case f[:type]
                 when "string_list" then :strs
                 when "i64_list" then :i64s
                 when CompositeTypes::MAP_FIELD then [:map, CompositeTypes::VALUES.fetch($1, [:untyped])[0]]
                 when /\A[A-Z]/ then [:obj, f[:type]]
                 else f[:type].to_sym
                 end
          f[:optional] && (base.is_a?(Symbol) || map?(base)) ? [:opt, base] : base
        end

        def helper_type(name)
          return [:opt, helper_type(name.chomp("?"))] if name.end_with?("?")

          case name
          when "string_list" then :strs
          when "i64_list" then :i64s
          else name.to_sym
          end
        end

        def owner_fields(entry)
          name = entry && entry[:text][/params:\s*:([A-Z]\w*)/, 1]
          name ? fields_of(name) : []
        end

        def block_names(list) = list.to_s.split(",").map(&:strip).reject(&:empty?)

        # --- scope inside a body --------------------------------------------------------------------------

        def env
          @env ||= build_env
        end

        def build_env
          @env = env = {}
          entry = body_entry
          return env unless entry

          head = entry[:text][/\bdo\s*\|([^|]*)\|/, 1]
          names = block_names(head)
          if entry[:kind] == :helper || (entry[:kind] == :inline && entry[:text].match?(/\A\s*helper\b/))
            args = entry[:text][/args:\s*\[([^\]]*)\]/, 1].to_s.scan(/:(\w+\??)/).flatten
            names.each_with_index { |n, i| env[n] = args[i] ? helper_type(args[i]) : :unknown }
          else
            fields = entry[:kind] == :inline ? [] : owner_fields(owner_entry)
            names.each { |n| env[n] = (f = fields.find { |x| x[:name] == n }) ? field_type(f) : :unknown }
          end
          from = entry[:kind] == :inline ? @above.size : entry[:line] + 1
          (from...@above.size).each { |i| assign(env, @above[i]) }
          @stack.each { |e| bind_block(env, e[:text], e[:params]) if e[:kind] == :block && e[:line] > entry[:line] }
          if (m = @prefix.match(/\{\s*\|([^|]*)\|(?!.*\})/))
            bind_block(env, @prefix[0...m.begin(0)], m[1], brace: true)
          end
          assign(env, @prefix)
          env
        end

        def assign(env, line)
          m = line.match(/\A\s*([a-z_]\w*)\s*=(?![=~>])\s*(.*)\z/) or return
          env[m[1]] = rhs_type(m[2], m[1])
        end

        def rhs_type(rhs, name)
          atoms, rest = chain_atoms(rhs)
          type = atoms ? eval_atoms(atoms) : :unknown
          type = type[1] if rest.match?(/\A\s*\|\|/) && type.is_a?(Array) && type[0] == :opt
          type = :unknown unless rest.strip.empty? || rest.match?(/\A\s*\|\|/)
          return type unless type == :unknown

          t = @a.types.select { |x| x[:name] == name && x[:line] < @line && %w[local parameter].include?(x[:kind]) }.last
          t ? Completion.type_of_display(t[:type]) : :unknown
        end

        # `list.select { |w|`: the block parameter is the element of the list the call is made on.
        def bind_block(env, before, params, brace: false)
          names = block_names(params)
          return if names.empty?

          before = before.sub(/\s+do\b.*\z/m, "") unless brace
          type = :unknown
          if (m = before.match(/\A(.*)\.(\w+[?!]?)\s*\z/m)) && (start = receiver_start(m[1]))
            recv = eval_text(m[1][start..])
            if %i[strs i64s].include?(recv) && LIST_BLOCKS.include?(m[2])
              type = Completion.element(recv)
            elsif INTS.include?(recv) && %w[times upto downto].include?(m[2])
              type = :i64
            end
          end
          names.each { |n| env[n] = type }
        end

        # --- receivers ------------------------------------------------------------------------------------

        def dot_items(match)
          pre = @prefix[0...match.begin(0)]
          start = receiver_start(pre)
          type = start ? receiver_type(pre, start) : :unknown
          return all_method_items if type == :unknown

          if type.is_a?(Array) && type[0] == :obj
            field_items(type[1])
          else
            Completion.methods_for(type).reject { |m| m.name == "[]" && !map?(type) }.map { |m| method_item(m, type) }
          end
        end

        def map?(type) = type.is_a?(Array) && type[0] == :map

        def receiver_type(pre, start)
          want = pre.bytesize + 1
          from = pre[0...start].bytesize + 1
          hits = @a.types.select { |t| t[:line] == @line && t[:end_line] == @line && t[:end_col] == want }
          hit = hits.find { |t| t[:col] == from } || hits.min_by { |t| t[:col] }
          type = hit ? Completion.type_of_display(hit[:type]) : :unknown
          type == :unknown ? eval_text(pre[start..]) : type
        end

        def method_item(meth, type)
          ret = Completion.resolve(meth.ret, type)
          detail = ret == :unknown ? "(#{meth.arity} args)" : "→ #{Completion.display(ret)}"
          insert, snippet = insert_for(meth)
          item(meth.name, :method, detail, doc: "#{Completion.display(type)}##{meth.name}", insert: insert, snippet: snippet)
        end

        def insert_for(meth)
          return [nil, false] if meth.name.end_with?("?") && meth.arity == "0" && !meth.block
          return ["#{meth.name} { |${1:x}| $0 }", true] if meth.block && meth.arity == "0"
          return ["#{meth.name}($1)", true] unless meth.arity == "0" || meth.name == "[]"

          [nil, false]
        end

        def all_method_items
          by_name = {}
          [:string, :strs, :i64s, :i64, :f64, :bool, [:opt, :string]].each do |type|
            Completion.methods_for(type).each { |m| (by_name[m.name] ||= []) << [type, m] unless m.name == "[]" }
          end
          by_name.map do |name, entries|
            kinds = entries.map { |t, _| Completion.display(t) }.uniq
            doc = entries.map { |t, m| "#{Completion.display(t)}##{name} → #{Completion.display(Completion.resolve(m.ret, t))}" }.join("\n")
            item(name, :method, kinds.join(", "), doc: doc, sort: "2")
          end
        end

        def field_items(name)
          fields_of(name).map do |f|
            item(f[:name], :field, Completion.display(field_type(f)), doc: f[:doc])
          end
        end

        # The start (a character index into s) of the receiver expression that ends at the end of s: a chain of
        # words, calls, index and block groups and literals, joined by dots.
        def receiver_start(s)
          i = s.length
          found = false
          loop do
            j = atom_start(s, i) or break
            found = true
            i = j
            if s[i - 1] == "." then i -= 1
            else break
            end
            i -= 1 if s[i - 1] == "&"
          end
          found ? i : nil
        end

        def atom_start(s, i)
          grouped = false
          while i.positive? && ")]}".include?(s[i - 1])
            block = s[i - 1] == "}"
            i = match_back(s, i - 1) or return nil
            grouped = true
            i -= 1 while block && i.positive? && s[i - 1] == " "
          end
          return s.rindex(s[i - 1], i - 2) if i > 1 && s[i - 1].match?(/["']/)

          j = i
          j -= 1 while j.positive? && s[j - 1].match?(/[\w?!@$]/)
          return j if j < i

          grouped ? i : nil
        end

        def match_back(s, close)
          pair = { ")" => "(", "]" => "[", "}" => "{" }
          depth = 0
          close.downto(0) do |k|
            c = s[k]
            if pair.key?(c) then depth += 1
            elsif pair.value?(c)
              depth -= 1
              return k if depth.zero?
            end
          end
          nil
        end

        def match_forward(s, open)
          pair = { "(" => ")", "[" => "]", "{" => "}" }
          depth = 0
          quote = nil
          (open...s.length).each do |k|
            c = s[k]
            if quote
              quote = nil if c == quote && s[k - 1] != "\\"
            elsif c == '"' || c == "'" then quote = c
            elsif pair.key?(c) then depth += 1
            elsif pair.value?(c)
              depth -= 1
              return k if depth.zero?
            end
          end
          nil
        end

        # text -> [atoms, rest]; atoms are [:base, kind, value] then [:call, name]; nil atoms when no chain starts.
        def chain_atoms(text)
          s = text.lstrip
          i = 0
          atoms = []
          if (m = s.match(/\A("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')/))
            atoms << [:base, :lit, :string]
            i = m[0].length
          elsif (m = s.match(/\A\d+\.\d+/))
            atoms << [:base, :lit, :f64]
            i = m[0].length
          elsif (m = s.match(/\A\d+/))
            atoms << [:base, :lit, :int]
            i = m[0].length
          elsif s.start_with?("[", "(", "{")
            close = match_forward(s, 0) or return [nil, text]
            atoms << [:base, :lit, literal_type(s, close)]
            i = close + 1
          elsif (m = s.match(/\A[a-z_]\w*[?!]?/))
            atoms << [:base, :name, m[0]]
            i = m[0].length
          else
            return [nil, text]
          end
          i = groups(s, i, atoms, atoms.first)
          while (m = s[i..].match(/\A&?\.([a-z_]\w*[?!]?)/))
            atoms << [:call, m[1]]
            i += m[0].length
            i = groups(s, i, atoms, nil)
          end
          [atoms, s[i..].to_s]
        end

        # Skips argument, index and block groups after an atom; an index group is a call to [].
        def groups(s, i, atoms, base)
          loop do
            rest = s[i..].to_s
            lead = rest[/\A\s*(?=\{)/] || ""
            ch = rest[lead.length]
            break unless ch && (lead.empty? ? "([{".include?(ch) : ch == "{")

            close = match_forward(s, i + lead.length) or break
            atoms << [:call, "[]"] if ch == "["
            atoms << [:args] if ch == "(" && base
            i = close + 1
          end
          i
        end

        def literal_type(s, close)
          inner = s[1...close]
          case s[0]
          when "[" then array_literal(inner)
          when "{" then map_literal(inner)
          else :unknown
          end
        end

        # `{ "a" => 1 }`: a map of the one type its values share; `{}` is a map of T.untyped.
        def map_literal(inner)
          return [:map, :untyped] if inner.strip.empty?

          kinds = split_args(inner).map do |pair|
            value = pair.match(/\A\s*"(?:\\.|[^"\\])*"\s*=>\s*(.*)\z/m)&.[](1) or return :unknown
            kind = eval_text(value)
            { int: :i64, i32: :i64 }.fetch(kind, kind)
          end.uniq
          kinds.size == 1 && Completion.map_value?(kinds.first) ? [:map, kinds.first] : :unknown
        end

        def array_literal(inner)
          return :strs if inner.match?(/\A\s*(?:"[^"]*"\s*,?\s*)+\z/)
          return :i64s if inner.match?(/\A\s*(?:\d+\s*,?\s*)+\z/)

          :unknown
        end

        def eval_text(text)
          atoms, rest = chain_atoms(text)
          return :unknown unless atoms && rest.strip.empty?

          eval_atoms(atoms)
        end

        def eval_atoms(atoms)
          type = :unknown
          atoms.each_with_index do |a, idx|
            case a[0]
            when :base
              type = if a[1] == :lit then a[2]
                     elsif %w[true false].include?(a[2]) then :bool
                     elsif atoms[idx + 1]&.first == :args && @helpers[a[2]] then @helpers[a[2]][:ret]
                     else env.fetch(a[2], :unknown)
                     end
            when :call
              type = if type.is_a?(Array) && type[0] == :obj
                       (f = fields_of(type[1]).find { |x| x[:name] == a[1] }) ? field_type(f) : :unknown
                     else
                       Completion.result_of(type, a[1])
                     end
            end
          end
          type
        end

        # --- body: names in scope -------------------------------------------------------------------------

        def body_items
          m = @prefix.match(/(?<![\w.:@$])(\w*)\z/) or return []
          return [] if m[1].match?(/\A\d/)

          list = env.map { |n, t| item(n, :variable, Completion.display(t), sort: "0") }
          list += @helpers.map do |n, h|
            item(n, :function, "helper → #{Completion.display(h[:ret])}", insert: "#{n}($1)", snippet: true, sort: "1")
          end
          list += KEYWORDS.map { |k| item(k, :keyword, "keyword", sort: "2") }
          filter(list, m[1])
        end

        # `body do |` and `|a, `: the field names of the enclosing declaration's params, minus those listed.
        def pipe_items
          m = @prefix.match(BODY_HEAD) or return []
          return [] if m[1].start_with?("helper")

          parts = m[2].split(",", -1)
          typed = parts.pop.to_s.strip
          given = parts.map(&:strip)
          items = owner_fields(owner_entry).reject { |f| given.include?(f[:name]) }.map do |f|
            item(f[:name], :variable, Completion.display(field_type(f)), doc: f[:doc], sort: "0")
          end
          filter(items, typed)
        end

        # --- declarations ---------------------------------------------------------------------------------

        # [continuation?, text]: a line after one ending in a comma continues that call's arguments.
        def logical_head
          parts = []
          k = @above.size - 1
          while k >= 0 && clean(@above[k]).rstrip.end_with?(",")
            parts.unshift(@above[k].strip)
            k -= 1
          end
          [parts.any?, (parts + [@prefix.lstrip]).join(" ")]
        end

        def dsl_items
          cont, head = logical_head
          if !cont && (m = @prefix.match(/\A\s*([a-z_]*)\z/))
            return filter(statement_items, m[1])
          end

          m = head.match(/\A\s*(\w+)(?:\s+|\()(.*)\z/m) or return []
          sig = SIG[m[1].to_sym] or return []
          segs = split_args(m[2])
          cur = segs.last.to_s
          if (k = cur.match(/\A\s*(\w+):(?!:)\s*(.*)\z/m))
            kind = sig[:kw][k[1].to_sym] or return []
            return value_items(kind[0], k[2], k[1])
          end
          idx = segs.size - 1
          if idx < sig[:pos].size
            value_items(sig[:pos][idx], cur, nil, positional: true)
          else
            kw_items(m[1].to_sym, sig, segs[0...-1].join(","), cur)
          end
        end

        # The accepted strings of a keyword listed in Docs::CHOICES, inside `audience: [` and `audience: ["us`: the
        # open quote is the one place a string is wanted, so this runs before the in-string check. nil when the
        # cursor is not in such a list.
        def choice_items
          _, head = logical_head
          m = head.match(/\A\s*(\w+)(?:\s+|\()(.*)\z/m) or return nil
          sig = SIG[m[1].to_sym] or return nil
          cur = split_args(m[2]).last.to_s
          k = cur.match(/\A\s*(\w+):(?!:)\s*\[(.*)\z/m) or return nil
          return nil unless sig[:kw].key?(k[1].to_sym) && (values = Docs.choices(m[1], k[1]))

          inner = k[2]
          typed = inner.split(",", -1).last.to_s.match(/\A\s*(")?(\w*)\z/) or return []
          given = inner.scan(/"(\w+)"\s*,/).flatten
          list = (values - given).map do |v|
            item(typed[1] ? v : "\"#{v}\"", :value, "#{k[1]} value", doc: markdown(Docs.keyword(m[1], k[1])), insert: typed[1] ? v : "\"#{v}\"", filter: v)
          end
          filter(list, typed[2])
        end

        def markdown(text) = text && { "kind" => "markdown", "value" => text }

        def split_args(text)
          segs = [+""]
          depth = 0
          quote = nil
          text.each_char do |c|
            if quote
              quote = nil if c == quote
            elsif c == '"' || c == "'" then quote = c
            elsif "([{".include?(c) then depth += 1
            elsif ")]}".include?(c) then depth -= 1
            elsif c == "," && depth <= 0
              segs << +""
              next
            end
            segs.last << c
          end
          segs
        end

        def statement_items
          ctx = @stack.empty? ? :top : @stack.last[:kind]
          SIG.filter_map do |name, sig|
            next unless Array(sig[:in]).include?(ctx)

            item(name.to_s, :snippet, DOCS.fetch(name.to_s, "DSL declaration"), doc: markdown(Docs.call(name)),
                 insert: snippet_for(name, sig), snippet: true)
          end
        end

        def snippet_for(name, sig)
          n = 0
          pos = sig[:pos].each_with_index.map { |kind, i| placeholder(kind, n += 1, sig[:names][i]) }
          kws = sig[:kw].select { |_, (_, req)| req }.map { |k, (kind, _)| "#{k}: #{placeholder(kind, n += 1, k)}" }
          line = [name.to_s, (pos + kws).join(", ")].reject(&:empty?).join(" ")
          case sig[:block]
          when :decls
            owner = OWNERS.include?(name)
            owner ? "#{line} do\n  body do |${#{n + 1}}|\n    $0\n  end\nend" : "#{line} do\n  $0\nend"
          when :body then "#{line} do |${#{n + 1}}|\n  $0\nend"
          else line
          end
        end

        def placeholder(kind, num, hint)
          case kind
          when :str then "\"${#{num}#{hint == :name ? ':name' : hint == :version ? ':0.1.0' : ''}}\""
          when :snake then ":${#{num}:#{hint || 'name'}}"
          when :camel then ":${#{num}:Name}"
          when Array then ":${#{num}|#{kind.join(',')}|}"
          when :fieldtype then ":${#{num}|#{(TYPES.keys + FIELD_LISTS).join(',')}|}"
          when :bool then "${#{num}|true,false|}"
          when :uint, :num then "${#{num}:0}"
          when :htypes, :types then "[:${#{num}:string}]"
          when :strs then "[\"${#{num}}\"]"
          else "${#{num}}"
          end
        end

        KIND_TEXT = { str: "string", bool: "true or false", camel: "a params/output name", uint: "integer", num: "number",
                      strs: "list of strings", htypes: "list of types", types: "list of types", lit: "literal",
                      snake: "snake_case name", fieldtype: "field type" }.freeze

        def kw_items(call, sig, given_text, cur)
          typed = cur[/\A\s*(\w*)\z/, 1] or return []
          given = given_text.scan(/\b(\w+):(?!:)/).flatten
          list = sig[:kw].reject { |k, _| given.include?(k.to_s) }.map do |k, (kind, req)|
            text = kind.is_a?(Array) ? "one of #{kind.first(4).join(', ')}" : KIND_TEXT.fetch(kind, kind.to_s)
            item("#{k}:", :property, "#{text}#{req ? ' (required)' : ''}", doc: markdown(Docs.keyword(call, k)),
                 insert: "#{k}: #{placeholder(kind, 1, k)}", snippet: true, sort: req ? "0" : "1", filter: k.to_s)
          end
          filter(list, typed)
        end

        def value_items(kind, typed, kwname, positional: false)
          case kind
          when Array then symbol_items(kind.map(&:to_s), typed) { "value" }
          when :fieldtype then field_type_items(typed)
          when :camel
            return [] if positional

            source = kwname == "output" ? @decls["output"] : @decls["params"]
            symbol_items(source.keys, typed) { kwname == "output" ? "output struct" : "params struct" }
          when :bool then filter(%w[true false].map { |b| item(b, :keyword, "boolean") }, typed.strip)
          when :htypes then type_list_items(HELPER_TYPES.keys.map(&:to_s).reject { |t| t.end_with?("?") }, typed)
          when :types then type_list_items(TYPES.keys.map(&:to_s), typed)
          else []
          end
        end

        COLLECTIONS = {
          "map(" => "A map from String keys to values of one type, such as map(:i64) or map(list(:string)).",
          "list(" => "A list of one type, such as list(:string); the same as :string_list or :i64_list."
        }.freeze
        MAP_VALUE_TYPES = %w[string i64 f64 bool].freeze
        LIST_ELEMENT_TYPES = %w[string i64].freeze

        # The type position of `field :name, `: the type symbols and nested params, and `map(` and `list(`; inside
        # `map(` the value types and `list(`, inside `list(` the element types.
        def field_type_items(typed)
          if (m = typed.match(/\A\s*map\(\s*(.*)\z/m))
            inner = m[1]
            return collection_inner(inner.match(/\Alist\(\s*(.*)\z/m)[1], LIST_ELEMENT_TYPES, "list element") if inner.match?(/\Alist\(/)

            list = symbol_items(MAP_VALUE_TYPES, inner) { |n| TYPES[n.to_sym] || n }
            return list + (inner.match?(/\A:/) ? [] : filter([collection_item("list(")], inner[/\A\w*/]))
          end
          if (m = typed.match(/\A\s*list\(\s*(.*)\z/m))
            return collection_inner(m[1], LIST_ELEMENT_TYPES, "list element")
          end

          names = (TYPES.keys + FIELD_LISTS).map(&:to_s)
          own = @stack.last && @stack.last[:text][/\A\s*(?:params|output)\s+:(\w+)/, 1]
          camel = @decls["params"].keys - [own]
          list = symbol_items(names + camel, typed) { |n| n.match?(/\A[A-Z]/) ? "nested object (params #{n})" : TYPES[n.to_sym] || "list" }
          word = typed[/\A\s*(\w*)\z/, 1]
          list + (word ? filter(COLLECTIONS.keys.map { |k| collection_item(k) }, word) : [])
        end

        def collection_inner(typed, names, what)
          symbol_items(names, typed) { |n| "#{what} type #{TYPES[n.to_sym] || n}" }
        end

        def collection_item(label)
          item(label, :snippet, label == "map(" ? "map type" : "list type", doc: COLLECTIONS.fetch(label),
               insert: "#{label}$0)", snippet: true, sort: "1")
        end

        def type_list_items(names, typed)
          inner = typed.match(/\A\s*\[(.*)\z/m) or return []
          symbol_items(names, inner[1].split(",", -1).last.to_s) { "type" }
        end

        def symbol_items(names, typed)
          m = typed.match(/\A\s*(:?)(\w*\??)\z/) or return []
          list = names.map do |n|
            item(":#{n}", :value, yield(n), insert: m[1].empty? ? ":#{n}" : n, filter: n)
          end
          filter(list, m[2])
        end
      end
    end
  end
end
