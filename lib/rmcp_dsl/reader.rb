# frozen_string_literal: true

module RmcpDsl
  # Walks the Prism AST of the DSL file into an IR hash (string keys, JSON-ready).
  # Deny by default: anything that is not a CallNode matching SIG is an error.
  class Reader
    include Diag

    def initialize(path, types: nil)
      @path = path
      @regexes = []
      @types = types # a TypeNames::Collector when `check --types` asks for the inferred types
      @flags = types ? { "types" => types } : {}
      @bindings = {}         # use_bindings name => BindingFile
      @binding_modules = {}  # module name (Heck) => BindingFile
      @binding_nodes = {}
      CompositeTypes::Opaque.reset # the types a binding owns are registered again as this file's use_bindings are read
      text = Lsp::Sources[path] # an editor's unsaved text, when the language server is compiling it
      res = text ? Prism.parse(text) : Prism.parse_file(path)
      unless res.errors.empty?
        raise CompileError, res.errors.map { |e|
          "#{path}:#{e.location.start_line}:#{e.location.start_column + 1}: syntax error: #{e.message}"
        }.join("\n")
      end
      @program = res.value
    end

    def read
      nodes = @program.statements.body
      bad(nodes[1] || @program, "expected exactly one top-level `server` call") unless nodes.size == 1
      pos, kw, blk = call(nodes[0], :top)
      bad(nodes[0], "server name must match [a-z][a-z0-9_-]*") unless pos[0].match?(/\A[a-z][a-z0-9_-]*\z/)
      bad(nodes[0], "version must be semver like 0.1.0, got #{kw[:version].inspect}") unless kw[:version].match?(SEMVER)
      srv = { "name" => pos[0], "version" => kw[:version], "instructions" => kw[:instructions], "params" => [], "tools" => [], "transport" => nil, "regexes" => @regexes,
             "crates" => [], "items" => [], "externs" => {}, "modules" => [], "subprocs" => [], "binding_fns" => [], "opaque_types" => [], "prompts" => [], "resources" => [], "outputs" => [],
             "title" => kw[:title], "description" => kw[:description], "website_url" => kw[:website_url], "icon" => kw[:icon] }
      if kw.key?(:page_size)
        bad(nodes[0], "`page_size:` is how many items one page of tools, prompts, resources and resource templates holds; it must be at least 1") if kw[:page_size] < 1
        srv["page_size"] = kw[:page_size]
      end
      check_uri(nodes[0], "icon", kw[:icon]) if kw[:icon]
      check_uri(nodes[0], "website_url", kw[:website_url], web_only: true) if kw[:website_url]
      pending = []
      helper_nodes = []
      prompt_nodes = []
      resource_nodes = []
      @helper_table = {}   # helpers compiled so far, in declaration order: name -> record
      @helper_decls = {}   # helper name -> its DSL node (for messages)
      each_child(blk, :server) do |n, p, k, b|
        case n.name
        when :params then srv["params"] << params_decl(n, p, b, srv)
        when :output then srv["outputs"] << output_decl(n, p, b, srv)
        when :tool then pending << [n, p, k, b]
        when :helper then helper_nodes << [n, p, k, b]
        when :prompt then prompt_nodes << [n, p, k, b]
        when :resource then resource_nodes << [n, p, k, b]
        when :rust_crate then add_crate(n, p, srv)
        when :rust_item then add_item(n, p, srv)
        when :rust_fn then add_extern(n, p, k, srv)
        when :rust_file then add_file(n, p, k, srv)
        when :use_bindings then add_bindings(n, p, srv)
        when :cmd_fn then add_cmd(n, p, k, srv)
        when :script_fn then add_script(n, p, k, srv)
        when :transport
          bad(n, "duplicate `transport`") if srv["transport"]
          srv["transport"] = p[0].to_s
          if srv["transport"] == "http"
            # rmcp has no default address to copy, so the port is the one thing the file has to say.
            bad(n, "`transport :http` needs `port:` (the generated server listens on 127.0.0.1 at that port)") unless k.key?(:port)
            bad(n, "`port:` must be 0 to 65535, got #{k[:port]}") if k[:port] > 65_535
            srv["port"] = k[:port]
          elsif k.key?(:port)
            bad(n, "`port:` only applies to `transport :http`")
          end
        end
      end
      bad(nodes[0], "missing `transport`") unless srv["transport"]
      srv["externs"].each do |fname, ext|
        next if ext["from"].nil? || srv["modules"].any? { |m| m["name"] == ext["from"] }

        bad(@extern_nodes.fetch(fname), "rust_fn `#{fname}` says from: :#{ext['from']}, but no rust_file has as: :#{ext['from']}")
      end
      helper_nodes.each { |n, p, k, b| helper_decl(n, p, k, b, srv) }
      srv["user_helpers"] = @helper_table.values
      pending.each { |n, p, k, b| srv["tools"] << tool_decl(n, p, k, b, srv) }
      prompt_nodes.each { |n, p, k, b| srv["prompts"] << prompt_decl(n, p, k, b, srv) }
      resource_nodes.each { |n, p, k, b| srv["resources"] << resource_decl(n, p, k, b, srv) }
      check_resource_overlaps(srv)
      check_notifications(srv)
      lower_bindings(srv)
      srv["checked"] = (@flags["checked"] || {}).keys.sort
      srv["helpers"] = (@flags["helpers"] || {}).keys.sort
      reject_unused_declarations(srv)
      warn_missing_module_fns(srv)
      srv
    end

    private

    # A declaration nothing uses would only become a rustc dead-code warning in the generated
    # crate. The DSL refuses it instead, so the file says exactly what the server does.
    def reject_unused_declarations(srv)
      called = @flags["used_externs"] || {}
      srv["externs"].each_key do |fname|
        next if called[fname]

        bad(@extern_nodes.fetch(fname),
            "`#{fname}` is declared but never called; call it as rust(:#{fname}, ...) in a tool body, or remove it")
      end
      called_helpers = @flags["used_helpers"] || {}
      @helper_table.each_key do |hname|
        next if called_helpers[hname]

        bad(@helper_decls.fetch(hname), "helper `#{hname}` is declared but never called; call it from a tool body or a later helper, or remove it")
      end
      # A params struct that only appears as another struct's nested field counts as used.
      used = srv["tools"].map { |t| t["params"] } + srv["prompts"].map { |t| t["params"] } + srv["resources"].filter_map { |t| t["params"] } +
             srv["params"].flat_map { |p| p["fields"].map { |f| f["type"] } }.select { |t| t.match?(CAMEL) }
      used_outputs = srv["tools"].filter_map { |t| t["output"] } +
                     srv["outputs"].flat_map { |p| p["fields"].map { |f| f["type"] } }.select { |t| t.match?(CAMEL) }
      srv["outputs"].each do |p|
        next if used_outputs.include?(p["name"])

        bad(@output_nodes.fetch(p["name"]), "output `#{p['name']}` is declared but no tool returns it; add `output: :#{p['name']}` to a tool, or remove it")
      end
      srv["params"].each do |p|
        next if used.include?(p["name"])

        bad(@params_nodes.fetch(p["name"]), "params `#{p['name']}` is declared but no tool uses it; remove it or add a tool")
      end
    end

    # Best effort, and only a warning: a rust_fn says its function lives in a loaded module, and a
    # text search of that file catches a typo at the DSL line instead of in generated Rust. The
    # compiler cannot see through macros or re-exports, so cargo stays the authority.
    def warn_missing_module_fns(srv)
      srv["externs"].each do |fname, ext|
        mod = srv["modules"].find { |m| m["name"] == ext["from"] } if ext["from"]
        next unless mod
        next if mod["source"].match?(/\bpub(?:\([^)]*\))?\s+(?:(?:const|async|unsafe)\s+)*fn\s+#{Regexp.escape(fname)}\b/)

        Notify.add(@path, @extern_nodes.fetch(fname), "W-RUST-FN-MISSING",
                   "`#{fname}` is declared as living in module `#{mod['name']}` (#{mod['path']}), " \
                   "but no `pub fn #{fname}` appears in that file; cargo will fail if it is really missing")
      end
    end

    # use_bindings :heck loads bindings/heck.rb from the directory of the DSL file (parsed, never run). Its crates join the server's.
    def add_bindings(node, pos, srv)
      name = pos[0]
      bad(node, "use_bindings :#{name} appears twice") if @bindings.key?(name)
      file = begin
        Bindings.load(name, root: Bindings.dir_for(@path))
      rescue CompileError => e
        bad(node, "cannot load binding `#{name}`: #{e.message}")
      end
      bad(node, "module `#{file.module_name}` is already provided by another binding") if @binding_modules.key?(file.module_name)
      file.crates.each do |crate, version|
        have = srv["crates"].find { |c| c["name"] == crate }
        if have && have["version"] != version
          bad(node, "binding `#{name}` needs crate #{crate} #{version}, but rust_crate says #{have['version']}")
        end
        add_crate(node, [crate, version], srv) unless have
      end
      file.types.each_value do |t|
        qualified = "#{file.module_name}::#{t.name}"
        CompositeTypes::Opaque.register(qualified, t.rust, t.wire)
        srv["opaque_types"] << { "name" => qualified, "rust" => t.rust, "wire" => t.wire }
      end
      @bindings[name] = file
      @binding_modules[file.module_name] = file
      @binding_nodes[name] = node
    end

    # After the tools are lowered: emit exactly the binding functions the bodies called, compile the
    # ones written in Ruby, and refuse a use_bindings that nothing uses.
    def lower_bindings(srv)
      used = @flags["used_bindings"] || {}
      @bindings.each do |name, file|
        fns = file.fns.values.select { |f| used["#{file.module_name}.#{f.name}"] }
        if fns.empty?
          bad(@binding_nodes[name], "use_bindings :#{name} is declared but no body calls #{file.module_name}.<method>; remove it or call it")
        end
        backed = fns.count(&:rust)
        crates = file.crates.map(&:first)
        Notify.add(@path, @binding_nodes[name], "N-BINDING",
                   "bindings/#{name}.rb: #{fns.size} function(s) used, #{backed} backed by Rust" \
                   "#{" (#{crates.join(', ')})" unless crates.empty?}, #{fns.size - backed} compiled from Ruby")
        fns.each do |fn|
          ir = file.descriptor(fn)
          unless fn.rust
            shown = File.join("bindings", File.basename(file.path)) # bindings/words.rb, like other messages
            body = Body.new(shown, { "fields" => [] }, @regexes, srv["externs"], @flags, nil, @binding_modules)
            ir["body"] = body.lower_def(fn)
          end
          srv["binding_fns"] << ir
        end
      end
    end

    OWN_CRATES = %w[rmcp serde schemars tokio anyhow regex].freeze

    def add_crate(node, pos, srv)
      name, ver = pos
      bad(node, "crate name must match [a-z][a-z0-9_-]*") unless name.match?(/\A[a-z][a-z0-9_-]*\z/)
      bad(node, "`#{name}` is already a dependency of every generated server") if OWN_CRATES.include?(name)
      bad(node, "crate version must look like 1, 1.2 or 1.2.3 (optionally ^ or ~)") unless ver.match?(/\A[\^~]?\d+(\.\d+){0,2}\z/)
      bad(node, "duplicate rust_crate `#{name}`") if srv["crates"].any? { |c| c["name"] == name }
      srv["crates"] << { "name" => name, "version" => ver }
    end

    def add_item(node, pos, srv)
      code = pos[0]
      bad(node, "rust_item is empty") if code.strip.empty?
      srv["items"] << code
      Notify.add(@path, node, "N-RUST-INJECTED",
                 "#{code.lines.size} line(s) of injected Rust; the compiler does not check them (cargo does)")
    end

    MAX_RS_BYTES = 1_000_000

    # rust_file "rust/x.rs", as: :x copies a hand-written file into the crate as module x.
    # The path comes from the DSL file, so it is confined to that file's own folder.
    def add_file(node, pos, kw, srv)
      rel = pos[0]
      mod = kw[:as].to_s
      if rel.start_with?("/") || rel.include?("\0") || rel.split("/").include?("..") || !rel.end_with?(".rs")
        bad(node, "rust_file path must be relative, inside the DSL file's folder, without .., and end in .rs")
      end
      bad(node, "module name `#{mod}` is reserved") if %w[tests main].include?(mod)
      bad(node, "duplicate rust_file module `#{mod}`") if srv["modules"].any? { |m| m["name"] == mod }
      base = File.realpath(File.dirname(File.expand_path(@path)))
      full = File.expand_path(rel, base)
      bad(node, "rust_file not found: #{rel}") unless File.file?(full)
      real = File.realpath(full)
      bad(node, "rust_file must stay inside #{base}") unless real.start_with?(base + File::SEPARATOR)
      bad(node, "rust_file is larger than #{MAX_RS_BYTES} bytes") if File.size(real) > MAX_RS_BYTES
      source = File.read(real, encoding: "UTF-8")
      bad(node, "rust_file is not valid UTF-8") unless source.valid_encoding?
      srv["modules"] << { "name" => mod, "path" => rel, "source" => source, "uses" => kw[:uses]&.to_s }
      Notify.add(@path, node, "N-RUST-INJECTED",
                 "#{rel} (#{source.lines.size} line(s)) loaded as module `#{mod}`; the compiler does not check it")
    end

    PROGRAM_RE = %r{\A[A-Za-z0-9._+/-]+\z}
    # interpreter => [flag that takes the source, extra argv before the call arguments]
    INTERPRETERS = { "python3" => ["-c"], "python" => ["-c"], "ruby" => ["-e"], "perl" => ["-e"],
                     "node" => ["-e"], "sh" => ["-c", "_"], "bash" => ["-c", "_"] }.freeze

    def add_cmd(node, pos, kw, srv)
      register_subproc(node, pos[0], kw[:program], kw[:argv] || [], kw[:args], (kw[:pass] || :argv).to_s, srv, "command")
    end

    def add_script(node, pos, kw, srv)
      interp = kw[:interpreter]
      flags = kw[:flag] ? [kw[:flag]] : INTERPRETERS[File.basename(interp)]
      bad(node, "script_fn needs flag: for interpreter `#{interp}` (known: #{INTERPRETERS.keys.join(', ')})") unless flags
      bad(node, "script_fn code is empty") if kw[:code].strip.empty?
      register_subproc(node, pos[0], interp, [flags[0], kw[:code], *flags.drop(1)], kw[:args], "argv", srv, "inline script")
    end

    # A subprocess is exposed to bodies as a rust_fn returning :string, so rust(:name, ...) works.
    def register_subproc(node, name, program, prefix, args, pass, srv, kind)
      bad(node, "program `#{program}` may only contain letters, digits and . _ + - /") unless program.match?(PROGRAM_RE)
      bad(node, "`#{name}` is already declared") if srv["externs"].key?(name)
      bad(node, "argv entries must not contain NUL") if prefix.any? { |s| s.include?("\0") }
      bad(node, "pass: :stdin needs exactly one :string argument") if pass == "stdin" && args != ["string"]
      srv["subprocs"] << { "name" => name, "program" => program, "argv" => prefix, "args" => args, "pass" => pass,
                           "line" => node.location.start_line }
      srv["externs"][name] = { "args" => args, "returns" => "string", "from" => nil }
      (@extern_nodes ||= {})[name] = node
      Notify.add(@path, node, "N-EXEC-INJECTED",
                 "#{kind} runs as subprocess `#{program}` on every call; the machine running the server needs it, and there is no sandbox")
    end

    def add_extern(node, pos, kw, srv)
      bad(node, "duplicate rust_fn `#{pos[0]}`") if srv["externs"].key?(pos[0])
      (@extern_nodes ||= {})[pos[0]] = node
      srv["externs"][pos[0]] = { "args" => kw[:args], "returns" => kw[:returns].to_s, "from" => kw[:from] }
    end

    NUMERIC_TYPES = %w[i32 i64 f64].freeze

    # Options on a `field`: optional, and JSON schema constraints the generated server also enforces.
    # Each option has to make sense for the field's type, so `min:` on a string is refused here.
    LIST_TYPES = %w[string_list i64_list].freeze

    def field_options(node, field, opts, srv, pool = srv["params"], label = "params")
      type = field["type"]
      if type.match?(CAMEL) # a nested object: the other struct must be declared above, so schemas cannot loop
        bad(node, "#{label} `#{type}` is not declared above this field; declare it first") unless pool.any? { |x| x["name"] == type }
        bad(node, "an optional nested object is not supported yet") if opts[:optional]
        stray = opts.keys - %i[description]
        bad(node, "`#{stray.first}:` does not apply to a nested object field") unless stray.empty?
        return
      end
      field["optional"] = true if opts[:optional]
      %i[min max].each do |key|
        next unless opts.key?(key)

        bad(node, "`#{key}:` applies to numeric fields, not :#{type}") unless NUMERIC_TYPES.include?(type)
        bad(node, "`#{key}:` must be an integer for an :#{type} field") if type != "f64" && !opts[key].is_a?(Integer)
        bad(node, "`#{key}:` does not fit in an :i32 field") if type == "i32" && !(-2**31..2**31 - 1).cover?(opts[key])
        field[key.to_s] = opts[key]
      end
      bad(node, "`min:` is above `max:`") if field["min"] && field["max"] && field["min"] > field["max"]
      %i[min_length max_length pattern enum format].each do |key|
        bad(node, "`#{key}:` applies to :string fields, not :#{type}") if opts.key?(key) && type != "string"
      end
      %i[min_items max_items].each do |key|
        next unless opts.key?(key)

        bad(node, "`#{key}:` applies to list fields, not :#{type}") unless LIST_TYPES.include?(type)
        field[key.to_s] = opts[key]
      end
      bad(node, "`min_items:` is above `max_items:`") if field["min_items"] && field["max_items"] && field["min_items"] > field["max_items"]
      %i[min_length max_length].each { |key| field[key.to_s] = opts[key] if opts.key?(key) }
      if field["min_length"] && field["max_length"] && field["min_length"] > field["max_length"]
        bad(node, "`min_length:` is above `max_length:`")
      end
      field["format"] = opts[:format].to_s.tr("_", "-") if opts.key?(:format)
      if opts.key?(:pattern)
        field["pattern"] = opts[:pattern]
        id = "RE_#{@regexes.size + 1}"
        @regexes << { "id" => id, "pattern" => opts[:pattern] }
        field["pattern_id"] = id
      end
      if opts.key?(:enum)
        bad(node, "`enum:` needs at least one value") if opts[:enum].empty?
        bad(node, "`enum:` values must be distinct") unless opts[:enum].uniq.size == opts[:enum].size
        field["enum"] = opts[:enum]
      end
      field_default(node, field, opts[:default]) if opts.key?(:default)
    end

    DEFAULT_KINDS = { "string" => "a string", "i32" => "an integer", "i64" => "an integer", "f64" => "a number",
                      "bool" => "true or false" }.freeze

    # A default makes the field always present (so it is not nil-able in the body) and is advertised in the
    # schema. It has to be a value the field would accept, so it is checked against the other options.
    def field_default(node, field, value)
      type = field["type"]
      bad(node, "`default:` and `optional:` cannot be combined (a field with a default is always present)") if field["optional"]
      bad(node, "`default:` applies to :string, :i32, :i64, :f64 and :bool fields, not :#{type}") unless DEFAULT_KINDS.key?(type)
      ok = case type
           when "string" then value.is_a?(String)
           when "i32", "i64" then value.is_a?(Integer)
           when "f64" then value.is_a?(Integer) || value.is_a?(Float)
           else value == true || value == false
           end
      bad(node, "`default:` must be #{DEFAULT_KINDS[type]} for the :#{type} field") unless ok
      bad(node, "`default:` does not fit in an :i32 field") if type == "i32" && !(-2**31..2**31 - 1).cover?(value)
      bad(node, "`default:` is below `min:`") if field["min"] && value < field["min"]
      bad(node, "`default:` is above `max:`") if field["max"] && value > field["max"]
      if value.is_a?(String)
        bad(node, "`default:` is shorter than `min_length:`") if field["min_length"] && value.length < field["min_length"]
        bad(node, "`default:` is longer than `max_length:`") if field["max_length"] && value.length > field["max_length"]
        bad(node, "`default:` is not one of the `enum:` values") if field["enum"] && !field["enum"].include?(value)
      end
      field["default"] = value
    end

    # A `meta:` value: a JSON object written as a literal (strings, numbers, true, false, nil, arrays, and hashes with
    # string keys), checked at compile time and sent as the `_meta` of a tool, prompt or resource. Its top-level keys
    # follow the MCP key-name rules (the 2025-06-18 basic specification, "_meta"): an optional prefix of dot-separated
    # labels and a slash, then a name; prefixes with `modelcontextprotocol` or `mcp` before another label are reserved.
    META_LABEL = /[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?/
    META_NAME = /(?:[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?)?/

    def meta_literal(node)
      bad(node, "`meta:` is a JSON object written as a literal, such as { \"com.example/tier\" => \"free\" }, got #{nodename(node)}") unless node.is_a?(Prism::HashNode)
      value = json_value(node)
      value.each_key { |key| check_meta_key(node, key) }
      value
    end

    def json_value(node)
      case node
      when Prism::StringNode then node.unescaped
      when Prism::IntegerNode
        bad(node, "this integer does not fit JSON number range (-2^63 to 2^64-1)") unless (-2**63..2**64 - 1).cover?(node.value)
        node.value
      when Prism::FloatNode then node.value
      when Prism::TrueNode then true
      when Prism::FalseNode then false
      when Prism::NilNode then nil
      when Prism::ArrayNode then node.elements.map { |el| json_value(el) }
      when Prism::HashNode then json_object(node)
      else
        bad(node, "`meta:` holds JSON data written out: strings, numbers, true, false, nil, arrays and hashes with string keys (got #{nodename(node)})")
      end
    end

    def json_object(node)
      seen = {}
      node.elements.each_with_object({}) do |el, out|
        bad(el, "a JSON object is `\"key\" => value` pairs; `**` is not supported") unless el.is_a?(Prism::AssocNode)
        if el.key.is_a?(Prism::SymbolNode)
          bad(el.key, "JSON object keys are strings: write \"#{el.key.unescaped}\" => value")
        end
        bad(el.key, "a JSON object key must be a string literal such as \"name\"") unless el.key.is_a?(Prism::StringNode)
        key = el.key.unescaped
        bad(el.key, "duplicate key \"#{key}\"") if seen[key]
        seen[key] = true
        out[key] = json_value(el.value)
      end
    end

    # Keys the specification itself reserves (progress, OpenTelemetry trace context).
    RESERVED_META_KEYS = %w[progressToken traceparent tracestate baggage].freeze

    def check_meta_key(node, key)
      bad(node, "`_meta` key \"#{key}\" is reserved by MCP (progress and trace context); pick another name, with your own prefix such as com.example/") if RESERVED_META_KEYS.include?(key)
      prefix, name = key.include?("/") ? key.split("/", 2) : [nil, key]
      if prefix
        labels = prefix.split(".", -1)
        unless labels.all? { |l| l.match?(/\A#{META_LABEL}\z/) }
          bad(node, "`_meta` key \"#{key}\" has an invalid prefix: it must be dot-separated labels that start with a letter and end with a letter or digit, then a slash (such as com.example/)")
        end
        # Reserved for MCP by either protocol revision: a second label of `modelcontextprotocol` or `mcp` (2026-07-28:
        # io.modelcontextprotocol/, dev.mcp/), or such a label followed by another one (2025-06-18: mcp.dev/,
        # tools.mcp.com/). A first-and-last-label `mcp` such as com.example.mcp/ is not reserved by either.
        mcp = %w[modelcontextprotocol mcp]
        if mcp.include?(labels[1]) || labels[0..-2].any? { |l| mcp.include?(l) }
          bad(node, "`_meta` key \"#{key}\" uses a prefix reserved for MCP (a label `modelcontextprotocol` or `mcp` in the second position, or followed by another label); use your own domain in reverse DNS, such as com.example/")
        end
      end
      return if name.match?(/\A#{META_NAME}\z/)

      bad(node, "`_meta` key \"#{key}\" has an invalid name: it must start and end with a letter or digit and may contain hyphens, underscores and dots")
    end

    # A field's type: a symbol (:string, :i64_list, :Address), `list(:string)` (the same as :string_list) or
    # `map(:i64)` (a typed map with String keys). Returns the canonical text the rest of the compiler reads:
    # "string", "string_list", "Address", "map(i64)", "map(string_list)".
    def field_type_expr(node, inside: nil)
      return field_collection(node, inside) if node.is_a?(Prism::CallNode) && node.receiver.nil? && %i[map list].include?(node.name)

      return opaque_field_type(node, inside) if node.is_a?(Prism::ConstantPathNode)

      bad(node, "expected a type symbol like :string, or map(...) / list(...), got #{nodename(node)}") unless node.is_a?(Prism::SymbolNode)
      s = node.unescaped
      unless TYPES.key?(s.to_sym) || FIELD_LISTS.include?(s.to_sym) || s.match?(CAMEL)
        bad(node, "`:#{s}` is not a field type (#{(TYPES.keys + FIELD_LISTS).map(&:inspect).join(" ")}, map(...), list(...), or the CamelCase name of another params)",
            word: s, from: TYPES.keys + FIELD_LISTS)
      end
      bad(node, "`:#{s}` is a Rust keyword") if RUST_KW.include?(s)
      s
    end

    # A field typed with a type a binding owns (`field :doc, Json::Value`): the binding must be loaded above, and the
    # type must say `wire: true`, because it becomes part of the tool's input or result schema.
    def opaque_field_type(node, inside)
      text = node.slice
      mod, _, name = text.rpartition("::")
      file = @binding_modules[mod]
      bad(node, "`#{inside}(#{text})` is not supported yet: collections hold basic types, not a binding's own types") if inside
      bad(node, "`#{text}`: no binding provides module `#{mod}` (declare `use_bindings :#{mod.downcase}` above the params)", word: mod, from: @binding_modules.keys) unless file
      type = file.types[name] or
        bad(node, "binding #{mod} has no type `#{name}` (its types: #{file.types.keys.join(', ').then { |s| s.empty? ? 'none' : s }})", word: name, from: file.types.keys)
      unless type.wire
        bad(node, "#{text} cannot be a field: its binding does not say `wire: true`. A field becomes part of the tool's schema, " \
                  "so the Rust type must be serde Serialize and Deserialize and schemars JsonSchema; add `wire: true` to its type_rust line if it is")
      end
      text
    end

    def field_collection(node, inside)
      args = node.arguments&.arguments || []
      example = node.name == :map ? "map(:i64)" : "list(:string)"
      bad(node, "`#{node.name}` takes one type, for example #{example}") unless args.size == 1 && node.block.nil?
      if inside && (node.name == :map || inside == :list)
        bad(node, "`#{inside}(...)` cannot hold `#{node.name}(...)` yet: maps of maps and lists of maps or lists are not supported")
      end
      inner = field_type_expr(args[0], inside: node.name)
      if node.name == :list
        return { "string" => "string_list", "i64" => "i64_list" }.fetch(inner) do
          bad(args[0], "`list(:#{inner})` is not supported yet; lists hold :string or :i64")
        end
      end
      return "map(#{inner})" if CompositeTypes::VALUES.key?(inner)

      hint = case inner
             when "i32" then "map values use :i64 for integers"
             when CAMEL then "maps of objects are not supported yet"
             else "map values can be :string, :i64, :f64, :bool, list(:string) or list(:i64)"
             end
      bad(args[0], "`map(:#{inner})` is not supported: #{hint}")
    end

    # Icons and website addresses are shown by clients, so they have to be real addresses: an icon may also be
    # an inline data: URI, a website only http or https.
    def check_uri(node, key, value, web_only: false)
      ok = value.match?(%r{\Ahttps?://[^\s/]+\S*\z}) || (!web_only && value.match?(/\Adata:[a-z]+\/[a-z0-9.+-]+[;,]\S+\z/))
      return if ok

      bad(node, "`#{key}:` must be an #{web_only ? 'http or https address' : 'http, https or data: URI'}, got #{value.inspect}")
    end

    # output :Summary do field ... end declares the structured result of a tool. The body builds it with
    # `Summary.new(field: value, ...)`; the client gets the fields as JSON plus an output schema. The server
    # does not check what it returns, so only types, descriptions and optional fields exist here.
    def output_decl(node, pos, blk, srv)
      (@output_nodes ||= {})[pos[0]] = node
      bad(node, "duplicate output `#{pos[0]}`") if srv["outputs"].any? { |x| x["name"] == pos[0] }
      bad(node, "`#{pos[0]}` is already the name of a params struct") if srv["params"].any? { |x| x["name"] == pos[0] }
      fields = []
      each_child(blk, :output) do |n, p, k, _b|
        bad(n, "duplicate field `#{p[0]}`") if fields.any? { |f| f["name"] == p[0] }
        stray = k.keys - %i[description optional]
        bad(n, "`#{stray.first}:` does not apply to an output field (the server does not check what it returns)") unless stray.empty?
        field = { "name" => p[0], "type" => p[1].to_s }
        field["description"] = k[:description] if k[:description]
        field_options(n, field, k, srv, srv["outputs"], "output")
        note_field(n, field)
        fields << field
      end
      bad(node, "output `#{pos[0]}` needs at least one `field`") if fields.empty?
      @types&.add(node.location, "output", pos[0], name: pos[0])
      { "name" => pos[0], "fields" => fields, "line" => node.location.start_line }
    end

    # Calls that already have a richer entry (field, helper, output) or no meaning of their own (body) are skipped.
    DECLARATION_SKIP = %i[field helper output body].freeze

    # One "declaration" entry per DSL call: the call, its keyword values as text, and where its name token
    # sits (the target of go-to-definition). The editor reads these for hover, definition and the outline.
    def note_declaration(node, pos, kw)
      return if DECLARATION_SKIP.include?(node.name)

      first = node.arguments&.arguments&.first
      extra = { call: node.name.to_s,
                keywords: kw.to_h { |k, v| [k.to_s, v.is_a?(Array) ? v.map(&:to_s) : v.to_s] } }
      if first.is_a?(Prism::SymbolNode) || first.is_a?(Prism::StringNode)
        loc = first.location
        extra.merge!(name_line: loc.start_line, name_col: loc.start_column + 1, name_end_col: loc.end_column + 1)
      end
      @types.add(node.location, "declaration", node.name.to_s, name: pos[0], extra: extra)
    end

    def note_field(node, field)
      @types&.add(node.location, "field", TypeNames.display(TypeNames.field_symbol(field)), name: field["name"])
    end

    def params_decl(node, pos, blk, srv)
      (@params_nodes ||= {})[pos[0]] = node
      bad(node, "duplicate params `#{pos[0]}`") if srv["params"].any? { |x| x["name"] == pos[0] }
      bad(node, "`#{pos[0]}` is already the name of an output") if srv["outputs"].any? { |x| x["name"] == pos[0] }
      fields = []
      each_child(blk, :params) do |n, p, k, _b|
        bad(n, "duplicate field `#{p[0]}`") if fields.any? { |f| f["name"] == p[0] }
        field = { "name" => p[0], "type" => p[1].to_s }
        field["description"] = k[:description] if k[:description]
        field_options(n, field, k, srv)
        note_field(n, field)
        fields << field
      end
      bad(node, "params `#{pos[0]}` needs at least one `field`") if fields.empty?
      { "name" => pos[0], "fields" => fields, "line" => node.location.start_line }
    end

    # Names a helper cannot take: they would collide with something the generated crate defines.
    RESERVED_HELPERS = %w[main check run_subprocess arith_error str_to_i str_to_int result].freeze

    # helper :guard, args: [:string], returns: :string do |url| ... end. A helper is compiled in declaration
    # order and may only call helpers declared above it, so recursion cannot happen. Types are never inferred.
    def helper_decl(node, pos, kw, blk, srv)
      name = pos[0]
      bad(node, "duplicate helper `#{name}`") if @helper_table.key?(name)
      bad(node, "helper `#{name}` has the same name as a rust_fn, cmd_fn or script_fn") if srv["externs"].key?(name)
      bad(node, "`#{name}` is reserved; pick another helper name") if RESERVED_HELPERS.include?(name) || name.start_with?("__")
      arg_syms = kw[:args].map(&:to_sym)
      arg_syms.each { |s| bad(node, "a helper parameter cannot be nil-able yet (:#{s})") if s.to_s.end_with?("?") }
      names = helper_params(blk, node)
      bad(node, "helper `#{name}` declares #{arg_syms.size} argument type(s) but its block takes #{names.size}") unless names.size == arg_syms.size
      arg_types = arg_syms.map { |s| HELPER_TYPES.fetch(s) }
      ret = HELPER_TYPES.fetch(kw[:returns])
      body = Body.new(@path, { "fields" => [] }, @regexes, srv["externs"], @flags, "helper `#{name}`", @binding_modules,
                      @helper_table.dup).lower_helper(blk, names, arg_types, ret)
      @helper_decls[name] = node
      @types&.add(node.location, "helper", "(#{arg_types.map { |t| TypeNames.display(t) }.join(", ")}) -> #{TypeNames.display(ret)}", name: name)
      @helper_table[name] = { "name" => name, "args" => names.zip(arg_types.map(&:to_s)), "returns" => ret.to_s,
                              "body" => body, "line" => node.location.start_line }
    end

    def helper_params(blk, node)
      ps = blk.parameters
      return [] unless ps

      bad(ps, "unsupported #{nodename(ps)} as helper parameters") unless ps.is_a?(Prism::BlockParametersNode)
      bad(ps, "block-local variables are not allowed") unless ps.locals.empty?
      pn = ps.parameters
      return [] unless pn

      extra = [pn.optionals, pn.posts, pn.keywords].any? { |x| !x.empty? } || pn.rest || pn.keyword_rest || pn.block
      bad(pn, "only plain required parameters are allowed") if extra
      pn.requireds.each_with_object([]) do |r, acc|
        bad(r, "unsupported #{nodename(r)} as a helper parameter") unless r.is_a?(Prism::RequiredParameterNode)
        bad(r, "parameter `#{r.name}` must be snake_case and not a Rust keyword") if !r.name.to_s.match?(SNAKE) || RUST_KW.include?(r.name.to_s)
        bad(r, "duplicate parameter `#{r.name}`") if acc.include?(r.name.to_s)
        acc << r.name.to_s
      end
    end

    # A prompt is a tool-shaped declaration whose body returns the text of one user message. MCP passes prompt
    # arguments as strings, so its params may only have :string fields (convert with to_i in the body).
    def prompt_decl(node, pos, kw, blk, srv)
      bad(node, "duplicate prompt `#{pos[0]}`") if srv["prompts"].any? { |x| x["name"] == pos[0] }
      prm = srv["params"].find { |x| x["name"] == kw[:params] } or
        undeclared(node, "prompt `#{pos[0]}` refers to undeclared params `#{kw[:params]}`", kw[:params], srv["params"].map { |x| x["name"] })
      if (field = prm["fields"].find { |f| f["type"] != "string" })
        bad(node, "prompt arguments are strings in MCP, but `#{field['name']}` is :#{field['type']}; use :string and convert with to_i in the body")
      end
      check_uri(node, "icon", kw[:icon]) if kw[:icon]
      # One `body` is one user message; `message :role do ... end` blocks make a conversation, in order.
      messages = []
      each_child(blk, :prompt) do |n, p, _k, b|
        role = n.name == :body ? "user" : p[0].to_s
        bad(n, "use either one `body` or one or more `message` blocks in a prompt, not both") if messages.any? && (n.name == :body || messages.any? { |m| m["single"] })
        lowered = Body.new(@path, prm, @regexes, srv["externs"], @flags, "prompt `#{pos[0]}`", @binding_modules, @helper_table, srv["params"]).lower(b)
        messages << { "role" => role, "body" => lowered, "single" => n.name == :body }
      end
      bad(node, "prompt `#{pos[0]}` needs a `body` or at least one `message`") if messages.empty?
      messages.each { |m| m.delete("single") }
      decl = { "name" => pos[0], "description" => kw[:description], "params" => prm["name"], "body" => messages.first["body"],
               "messages" => messages, "line" => node.location.start_line }
      decl["title"] = kw[:title] if kw[:title]
      decl["icon"] = kw[:icon] if kw[:icon]
      decl["meta"] = kw[:meta] if kw[:meta]
      decl
    end

    # A uri with {placeholders} is a resource template (RFC 6570). The forms supported are {name}, {a,b} (several values
    # separated by commas), {x*} (a list), {+path} (a value that may contain slashes) and {?q,limit} (optional query
    # variables). The uri is split into literal and expression parts here so every mistake is reported with the file
    # and line of the declaration. A segment is [:lit, text] or [:expr, operator, [[name, list?], ...], text].
    URI_CHARS = %r{\A[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%{}]*\z}
    TEMPLATE_OPERATORS = "+#./;?&=,!@|"
    SUPPORTED_OPERATORS = "+?"
    SUPPORTED_FORMS = "{name}, {a,b}, {x*}, {+path} and {?q,limit}"

    def parse_uri_template(node, uri)
      bad(node, "`uri:` must be ASCII (percent-encode other characters), got #{uri.inspect}") unless uri.ascii_only?
      bad(node, "`uri:` has `#{uri[/[^A-Za-z0-9\-._~:\/?#\[\]@!$&'()*+,;=%{}]/]}`, which is not allowed in a URI (RFC 3986); percent-encode it") unless uri.match?(URI_CHARS)
      segments = []
      literal = +""
      i = 0
      while i < uri.length
        ch = uri[i]
        if ch == "{"
          close = uri.index("}", i + 1) or bad(node, "`uri:` has an unclosed `{`; write placeholders as {name}")
          inner = uri[(i + 1)...close]
          bad(node, "`uri:` has a `{` inside a placeholder (`{#{inner}`); placeholders cannot nest") if inner.include?("{")
          segments << [:lit, literal] unless literal.empty?
          literal = +""
          expr = template_expr(node, inner)
          # a query starts with its own `?`, so it may follow another placeholder directly
          if segments.last&.first == :expr && expr[1] != "?"
            bad(node, "placeholders {#{segments.last.last}} and {#{inner}} touch; put text between them so the server can tell where one ends")
          end
          segments << expr
          i = close + 1
        elsif ch == "}"
          bad(node, "`uri:` has a `}` with no `{` before it")
        else
          literal << ch
          i += 1
        end
      end
      segments << [:lit, literal] unless literal.empty?
      check_template_shape(node, segments)
      names = segments.select { |s| s[0] == :expr }.flat_map { |s| s[2].map(&:first) }
      dup = names.find { |n| names.count(n) > 1 }
      bad(node, "placeholder {#{dup}} appears twice in `uri:`; every value needs its own name") if dup
      segments
    end

    # {?...} is the query: one of them, last in the uri, and no literal `?` before it (that would start a second query).
    def check_template_shape(node, segments)
      queries = segments.each_index.select { |i| segments[i][0] == :expr && segments[i][1] == "?" }
      return if queries.empty?

      bad(node, "`uri:` has more than one `{?...}`; put every query variable in one, such as {?a,b}") if queries.size > 1
      bad(node, "`{?...}` has to end the uri: the query comes last") unless queries[0] == segments.size - 1
      return unless segments.any? { |s| s[0] == :lit && s[1].include?("?") }

      bad(node, "`uri:` has a literal `?` and also a `{?...}`, which would start a second query; keep the query in the {?a,b} placeholder")
    end

    def template_expr(node, inner)
      bad(node, "`uri:` has an empty placeholder `{}`; name the value, for example {id}") if inner.empty?
      op = nil
      list = inner
      if TEMPLATE_OPERATORS.include?(inner[0])
        unless SUPPORTED_OPERATORS.include?(inner[0])
          bad(node, "`{#{inner}}` uses the RFC 6570 operator `#{inner[0]}`; the supported forms are #{SUPPORTED_FORMS}")
        end
        op = inner[0]
        list = inner[1..]
      end
      bad(node, "`uri:` has an empty placeholder `{#{inner}}`; name the value, for example {#{op}id}") if list.empty?
      specs = list.split(",", -1)
      bad(node, "`{#{inner}}` has an empty variable name between commas") if specs.any?(&:empty?)
      vars = specs.map do |spec|
        explode = spec.end_with?("*")
        name = explode ? spec[0...-1] : spec
        bad(node, "`{#{inner}}` uses the RFC 6570 prefix modifier `:`; the supported forms are #{SUPPORTED_FORMS}") if name.include?(":")
        [template_var(node, name), explode]
      end
      bad(node, "`{#{inner}}`: `+` takes one variable, such as {+path}") if op == "+" && vars.size > 1
      bad(node, "`{#{inner}}`: a list (`*`) stands alone; several values are written {a,b} without `*`") if op.nil? && vars.size > 1 && vars.any?(&:last)
      bad(node, "`{#{inner}}`: `*` on a query variable repeats it in the query (?x=1&x=2), which is not supported; write {?x}") if op == "?" && vars.any?(&:last)
      [:expr, op, vars, inner]
    end

    def template_var(node, name)
      bad(node, "`{#{name}}` is not a valid RFC 6570 variable name (letters, digits and _)") unless name.match?(/\A[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*\z/)
      unless name.match?(/\A[a-z][a-z0-9_]*\z/)
        suggestion = name.gsub(/([a-z0-9])([A-Z])/, '\1_\2').downcase.tr(".", "_")
        bad(node, "placeholder `{#{name}}` must be a snake_case field name like {#{suggestion.sub(/\A[0-9_]+/, '')}}")
      end
      name
    end

    # The variables of a template in uri order, each with the number of the regex group that captures it (a query's
    # variables share one group, which holds the whole query string).
    def template_vars(segments)
      group = 0
      segments.select { |s| s[0] == :expr }.flat_map do |_, op, vars, _|
        if op == "?"
          group += 1
          vars.map { |name, _| { "name" => name, "op" => op, "explode" => false, "group" => group } }
        else
          vars.map { |name, explode| { "name" => name, "op" => op, "explode" => explode, "group" => (group += 1) } }
        end
      end
    end

    # The params of a template resource: one field per variable, nothing else. A plain variable is a :string; {x*} is a
    # :string_list; a query variable may be missing from the uri, so its field is `optional: true` (nil in the body).
    def template_params(node, name, kw, vars, srv)
      if vars.empty?
        bad(node, "`params:` only applies to a `uri:` with {placeholders}; add one such as {id}, or remove `params:`") if kw[:params]
        return nil
      end
      names = vars.map { |v| v["name"] }
      shown = names.map { |v| "{#{v}}" }.join(", ")
      kw[:params] or bad(node, "`uri:` has placeholders (#{shown}); add `params: :SomeParams` with a field for each (a :string, or a :string_list for {x*})")
      prm = srv["params"].find { |x| x["name"] == kw[:params] } or
        undeclared(node, "resource `#{name}` refers to undeclared params `#{kw[:params]}`", kw[:params], srv["params"].map { |x| x["name"] })
      fields = prm["fields"].map { |f| f["name"] }
      (names - fields).each do |v|
        near = fields.find { |f| f.delete("_") == v.delete("_").downcase }
        bad(node, "placeholder `{#{v}}` has no field in params `#{prm['name']}` (fields: #{fields.join(', ')})#{near ? "; did you mean {#{near}}?" : ''}")
      end
      (fields - names).each do |f|
        bad(node, "field `#{f}` of params `#{prm['name']}` is not in the uri; add {#{f}} to `uri:` or remove the field")
      end
      prm["fields"].each do |f|
        v = vars.find { |x| x["name"] == f["name"] }
        if v["explode"]
          bad(node, "`{#{f['name']}*}` is a list, so `#{f['name']}` is a :string_list, not :#{f['type']}") unless f["type"] == "string_list"
        else
          bad(node, "resource arguments come from the URI, so they are strings; `#{f['name']}` is :#{f['type']}") unless f["type"] == "string"
        end
        if v["op"] == "?"
          bad(node, "`{?#{f['name']}}` may be missing from the uri, so `#{f['name']}` needs `optional: true` (it is nil in the body when absent)") unless f["optional"]
          bad(node, "`default:` does not apply to `#{f['name']}`: write `|| \"value\"` in the body instead") if f.key?("default")
        elsif f["optional"] || f.key?("default")
          bad(node, "`optional:` and `default:` do not apply to `#{f['name']}`: the URI always supplies it (an empty value is still a value)")
        end
      end
      prm
    end

    # A placeholder matches any characters up to the next /, ? or #. It may be empty (RFC 6570 gives an empty string
    # a defined value), so a `pattern:` or `min_length:` on the field is how a file refuses it. {+x} also matches
    # slashes, {a,b} matches comma-separated values, and the query is one optional group holding the whole query string.
    def template_pattern(segments)
      body = segments.map do |seg|
        case seg[0]
        when :lit then seg[1].gsub(/[\\.+*?()|\[\]{}^$#&\-~]/) { |m| "\\#{m}" }
        else
          case seg[1]
          when "?" then "(?:\\?([^#]*))?"
          when "+" then "([^?#]*)"
          else seg[2].size > 1 ? seg[2].map { "([^/?#,]*)" }.join(",") : "([^/?#]*)"
          end
        end
      end.join
      "^#{body}$"
    end
    # Two resources must never be able to answer the same uri, so which one wins is never a guess.
    def check_resource_overlaps(srv)
      shapes = srv["resources"].map do |res|
        segs = parse_uri_template(@resource_nodes.fetch(res["name"]), res["uri"])
        sample = segs.map { |seg| seg[0] == :lit ? seg[1] : (seg[1] == "?" ? "" : seg[2].map { "x" }.join(",")) }.join
        [res, Regexp.new(template_pattern(segs)), sample]
      end
      shapes.combination(2) do |(a, re_a, sample_a), (b, re_b, sample_b)|
        next unless re_a.match?(sample_b) || re_b.match?(sample_a)

        bad(@resource_nodes.fetch(b["name"]), "resource `#{b['name']}` (`#{b['uri']}`) and resource `#{a['name']}` (`#{a['uri']}`) can match the same uri; make them differ, for example with a literal segment")
      end
    end

    # A resource is readable text at a URI. A plain uri takes no parameters and runs on every read; a uri with
    # {placeholders} is a template whose body gets the matched values.
    def resource_decl(node, pos, kw, blk, srv)
      bad(node, "duplicate resource `#{pos[0]}`") if srv["resources"].any? { |x| x["name"] == pos[0] }
      segments = parse_uri_template(node, kw[:uri]) # first, so a bad character or brace gets its specific message
      bad(node, "`uri:` must look like scheme://path, got #{kw[:uri].inspect}") unless kw[:uri].match?(%r{\A[A-Za-z][A-Za-z0-9+.-]*://\S+\z})
      bad(node, "duplicate resource uri #{kw[:uri]}") if srv["resources"].any? { |x| x["uri"] == kw[:uri] }
      (@resource_nodes ||= {})[pos[0]] = node
      vars = template_vars(segments)
      prm = template_params(node, pos[0], kw, vars, srv)
      check_uri(node, "icon", kw[:icon]) if kw[:icon]
      if kw[:audience]
        bad(node, "`audience:` needs at least one of \"user\", \"assistant\"") if kw[:audience].empty?
        odd = kw[:audience].find { |a| !%w[user assistant].include?(a) }
        bad(node, "`audience:` values are \"user\" or \"assistant\", got #{odd.inspect}") if odd
        bad(node, "`audience:` values must be distinct") unless kw[:audience].uniq.size == kw[:audience].size
      end
      bad(node, "`priority:` is between 0 and 1 (1 is most important), got #{kw[:priority]}") if kw[:priority] && !(0..1).cover?(kw[:priority])
      bad(node, "`size:` is for a resource with one fixed uri; a template stands for many resources of different sizes") if kw[:size] && prm
      body = nil
      each_child(blk, :resource) do |n, _p, _k, b|
        bad(n, "duplicate `body`") if body
        check_resource_size(node, kw[:size], b) if kw[:size]
        bad(b.parameters, "a resource body takes no parameters (give the uri `{placeholders}` and `params:` to pass it values)") if b.parameters && !prm
        body = Body.new(@path, prm || { "fields" => [] }, @regexes, srv["externs"], @flags, "resource `#{pos[0]}`", @binding_modules, @helper_table,
                        srv["params"]).lower(b)
      end
      bad(node, "resource `#{pos[0]}` needs a `body`") unless body
      template = {}
      if prm
        regex_id = "RE_#{@regexes.size + 1}"
        @regexes << { "id" => regex_id, "pattern" => template_pattern(segments) }
        template = { "template" => true, "params" => prm["name"], "vars" => vars, "regex_id" => regex_id }
      end
      { "name" => pos[0], "uri" => kw[:uri], "description" => kw[:description], "mime_type" => kw[:mime_type], **template,
        "title" => kw[:title], "icon" => kw[:icon], "meta" => kw[:meta], "audience" => kw[:audience], "priority" => kw[:priority],
        "size" => kw[:size], "body" => body, "line" => node.location.start_line }
    end

    # `size:` is what clients show as the resource's size and use to estimate how much of a model's context it takes
    # (the specification: the size of the raw content in bytes, before base64 or tokenization). When the body is a
    # plain string, the compiler knows that size and refuses a number that is wrong; for a computed body it cannot,
    # so the number is the author's word.
    def check_resource_size(node, size, body_block)
      last = body_block.body&.body&.last
      return unless last.is_a?(Prism::StringNode)

      actual = last.unescaped.bytesize
      return if actual == size

      bad(node, "`size: #{size}` is not the size of the body, which is #{actual} bytes (UTF-8); use `size: #{actual}`, or leave `size:` out")
    end

    def tool_decl(node, pos, kw, blk, srv)
      bad(node, "duplicate tool `#{pos[0]}`") if srv["tools"].any? { |t| t["name"] == pos[0] }
      prm = srv["params"].find { |x| x["name"] == kw[:params] } or
        undeclared(node, "tool `#{pos[0]}` refers to undeclared params `#{kw[:params]}`", kw[:params], srv["params"].map { |x| x["name"] })
      out = nil
      if kw[:output]
        out = srv["outputs"].find { |x| x["name"] == kw[:output] } or
          undeclared(node, "tool `#{pos[0]}` refers to undeclared output `#{kw[:output]}`", kw[:output], srv["outputs"].map { |x| x["name"] })
      end
      body = nil
      each_child(blk, :tool) do |n, _p, _k, b|
        bad(n, "duplicate `body`") if body
        body = Body.new(@path, prm, @regexes, srv["externs"], @flags, "tool `#{pos[0]}`", @binding_modules, @helper_table,
                        srv["params"], srv["outputs"]).lower(b, out && out["name"])
      end
      bad(node, "tool `#{pos[0]}` needs a `body`") unless body
      decl = { "name" => pos[0], "description" => kw[:description], "params" => prm["name"], "body" => body,
               "line" => node.location.start_line }
      decl["output"] = out["name"] if out
      decl["icon"] = kw[:icon] if kw[:icon]
      decl["meta"] = kw[:meta] if kw[:meta]
      task_options(node, kw, decl)
      resource_notifications(node, kw, prm, decl)
      (@tool_nodes ||= {})[pos[0]] = node
      check_uri(node, "icon", kw[:icon]) if kw[:icon]
      annotations = %i[title read_only destructive idempotent open_world].select { |key| kw.key?(key) }.to_h { |key| [key.to_s, kw[key]] }
      if kw[:read_only] == true && (kw.key?(:destructive) || kw.key?(:idempotent))
        bad(node, "`destructive:` and `idempotent:` only mean something when `read_only:` is false")
      end
      decl["annotations"] = annotations unless annotations.empty?
      decl
    end

    # `updates: ["notes://guide", "notes://notes/{id}"]` says which resources this tool changes: once the tool succeeds,
    # clients subscribed to those uris are told (notifications/resources/updated). A {field} is filled from the tool's
    # params ({+field} keeps reserved characters such as /, as {+path} does in a template). `resource_list_changed: true`
    # says the tool adds or removes resources, so clients that asked are told the list changed. Which resources exist
    # is checked once they are all declared (check_notifications).
    def resource_notifications(node, kw, prm, decl)
      if kw.key?(:updates)
        bad(node, "`updates:` needs at least one resource uri, such as [\"notes://guide\"]") if kw[:updates].empty?
        decl["updates"] = kw[:updates].map { |entry| update_target(node, entry, prm) }
      end
      bad(node, "`resource_list_changed: false` is the default; leave it out") if kw[:resource_list_changed] == false
      decl["list_changed"] = true if kw[:resource_list_changed]
    end

    def update_target(node, entry, prm)
      bad(node, "`updates:` entry #{entry.inspect} must look like scheme://path") unless entry.match?(%r{\A[A-Za-z][A-Za-z0-9+.-]*://\S+\z})
      parts = []
      literal = +""
      i = 0
      while i < entry.length
        case entry[i]
        when "{"
          close = entry.index("}", i + 1) or bad(node, "`updates:` entry #{entry.inspect} has an unclosed `{`")
          inner = entry[(i + 1)...close]
          plus = inner.start_with?("+")
          name = plus ? inner[1..] : inner
          names = prm["fields"].map { |f| f["name"] }
          field = prm["fields"].find { |f| f["name"] == name } or
            bad(node, "`updates:` placeholder {#{inner}} is not a field of the tool's params `#{prm['name']}` (fields: #{names.join(', ')})", word: name, from: names)
          bad(node, "`updates:` placeholder {#{inner}} is a :#{field['type']}; only a required :string field can fill a uri") unless field["type"] == "string" && !field["optional"]
          parts << ["lit", literal] unless literal.empty?
          literal = +""
          parts << ["var", name, plus]
          i = close + 1
        when "}" then bad(node, "`updates:` entry #{entry.inspect} has a `}` with no `{` before it")
        else
          literal << entry[i]
          i += 1
        end
      end
      parts << ["lit", literal] unless literal.empty?
      parts
    end

    # Once every resource is declared: each `updates:` uri has to be one a resource serves (a fixed uri, or a template
    # that the uri with its placeholders filled matches), and `resource_list_changed:` needs resources to change.
    def check_notifications(srv)
      shapes = srv["resources"].map do |res|
        segs = parse_uri_template(@resource_nodes.fetch(res["name"]), res["uri"])
        [res, Regexp.new(template_pattern(segs))]
      end
      srv["tools"].each do |tool|
        node = @tool_nodes.fetch(tool["name"])
        bad(node, "tool `#{tool['name']}` says `resource_list_changed: true`, but the server declares no resources") if tool["list_changed"] && srv["resources"].empty?
        (tool["updates"] || []).each do |parts|
          sample = parts.map { |kind, text| kind == "lit" ? text : "x" }.join
          next if shapes.any? { |res, re| res["template"] ? re.match?(sample) : res["uri"] == sample }

          shown = parts.map { |kind, text, plus| kind == "lit" ? text : "{#{plus ? '+' : ''}#{text}}" }.join
          have = srv["resources"].map { |r| r["uri"] }
          bad(node, "tool `#{tool['name']}` says `updates: [#{shown.inspect}]`, but no resource serves that uri (#{have.empty? ? 'none is declared' : "declared: #{have.join(', ')}"})")
        end
      end
    end

    # `task: true` lets a client that declared the tasks extension (io.modelcontextprotocol/tasks) get a task handle
    # instead of waiting for the result; the server decides per request and runs the same body either way. The time
    # to live and the suggested polling interval are the extension's `ttlMs` and `pollIntervalMs` (rmcp's defaults
    # are 300000 and 1000).
    def task_options(node, kw, decl)
      extra = %i[task_ttl_ms task_poll_ms].select { |k| kw.key?(k) }
      if kw[:task] != true
        bad(node, "`#{extra.first}:` only applies with `task: true`") unless extra.empty?
        bad(node, "`task: false` is the default; leave `task:` out") if kw[:task] == false
        return
      end
      extra.each { |k| bad(node, "`#{k}:` must be at least 1 millisecond") if kw[k] < 1 }
      decl["task"] = { "ttl_ms" => kw[:task_ttl_ms], "poll_ms" => kw[:task_poll_ms] }.compact
    end

    # Yields (node, positional, keywords, block) for every DSL call directly inside blk.
    def each_child(blk, ctx)
      st = blk.body
      return unless st
      bad(st, "unsupported #{nodename(st)} in `#{ctx}` block") unless st.is_a?(Prism::StatementsNode)
      st.body.each do |n|
        p, k, b = call(n, ctx)
        yield n, p, k, b
      end
    end

    # Validates one call against SIG; returns [positional values, keyword values, block].
    def call(node, ctx)
      where = ctx == :top ? "the top level" : "`#{ctx}`"
      bad(node, "unsupported #{nodename(node)} in #{where} (only DSL calls are allowed)") unless node.is_a?(Prism::CallNode)
      sig = SIG[node.name] or bad(node, "unknown DSL call `#{node.name}` (valid in #{where}: #{calls_in(ctx).join(", ")})", word: node.name, from: calls_in(ctx))
      unless Array(sig[:in]).include?(ctx)
        bad(node, "`#{node.name}` is not allowed in #{where} (valid there: #{calls_in(ctx).join(", ")}); it belongs in #{Array(sig[:in]).map { |c| c == :top ? "the top level" : "`#{c}`" }.join(" or ")}")
      end
      bad(node.receiver, "`#{node.name}` takes no receiver") if node.receiver
      pos, kw = args(node, sig)
      note_declaration(node, pos, kw) if @types
      [pos, kw, block(node, sig)]
    end

    # The DSL calls allowed directly inside `ctx`.
    def calls_in(ctx) = SIG.select { |_, s| Array(s[:in]).include?(ctx) }.keys.map(&:to_s)

    # The call shape for error messages, e.g. `tool(name, params:, description:, [title:], ...)`: optional keywords are bracketed.
    def shape(name, sig)
      kws = sig[:kw].map { |k, (_, req)| req ? "#{k}:" : "[#{k}:]" }
      "#{name}(#{(sig[:names] + kws).join(", ")})"
    end

    # Refuses a reference to a params/output struct that was not declared above, listing what is.
    def undeclared(node, msg, name, declared)
      list = declared.empty? ? "none is declared above" : "declared above: #{declared.join(", ")}"
      bad(node, "#{msg} (#{list})", word: name, from: declared)
    end

    def args(node, sig)
      list = (node.arguments&.arguments || []).dup
      kwn = list.last.is_a?(Prism::KeywordHashNode) ? list.pop : nil
      unless list.size == sig[:pos].size
        bad(node, "`#{node.name}` takes #{sig[:pos].size} positional argument(s), got #{list.size}; expected `#{shape(node.name, sig)}`")
      end
      pos = list.zip(sig[:pos]).map { |n, want| value(n, want) }
      kw = {}
      (kwn ? kwn.elements : []).each do |el|
        ok = el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode) && !el.value.is_a?(Prism::ImplicitNode)
        bad(el, "unsupported #{nodename(el)} in `#{node.name}` arguments (no **opts, no shorthand `key:`)") unless ok
        key = el.key.unescaped.to_sym
        spec = sig[:kw][key] or bad(el, "unknown keyword `#{key}:` for `#{node.name}` (allowed: #{sig[:kw].keys.join(', ')})", word: key, from: sig[:kw].keys)
        bad(el, "duplicate keyword `#{key}:`") if kw.key?(key)
        kw[key] = value(el.value, spec[0])
      end
      sig[:kw].each { |k, (_, req)| bad(node, "`#{node.name}` requires `#{k}:`") if req && !kw.key?(k) }
      [pos, kw]
    end

    def value(node, want)
      return field_type_expr(node) if want == :fieldtype
      return meta_literal(node) if want == :json
      if want == :lit
        case node
        when Prism::IntegerNode, Prism::FloatNode then return node.value
        when Prism::StringNode then return node.unescaped
        when Prism::TrueNode then return true
        when Prism::FalseNode then return false
        else bad(node, "expected a string, number or true/false literal, got #{nodename(node)}")
        end
      end
      if want == :bool
        bad(node, "expected true or false, got #{nodename(node)}") unless node.is_a?(Prism::TrueNode) || node.is_a?(Prism::FalseNode)
        return node.is_a?(Prism::TrueNode)
      end
      if want == :num
        bad(node, "expected a number literal, got #{nodename(node)}") unless node.is_a?(Prism::IntegerNode) || node.is_a?(Prism::FloatNode)
        return node.value
      end
      if want == :uint
        bad(node, "expected a non-negative integer literal, got #{nodename(node)}") unless node.is_a?(Prism::IntegerNode) && !node.value.negative?
        return node.value
      end
      if want == :htypes
        bad(node, "expected an array of type symbols, got #{nodename(node)}") unless node.is_a?(Prism::ArrayNode)
        return node.elements.map { |el| value(el, HELPER_TYPES.keys).to_s }
      end
      if want == :types
        bad(node, "expected an array of type symbols, got #{nodename(node)}") unless node.is_a?(Prism::ArrayNode)
        return node.elements.map { |el| value(el, TYPES.keys).to_s }
      end
      if want == :strs
        bad(node, "expected an array of string literals, got #{nodename(node)}") unless node.is_a?(Prism::ArrayNode)
        return node.elements.map { |el| value(el, :str) }
      end
      if want == :str
        # A squiggly heredoc (<<~) arrives as an InterpolatedStringNode whose parts are plain
        # StringNode lines. Real interpolation adds an EmbeddedStatementsNode part and is refused.
        if node.is_a?(Prism::InterpolatedStringNode) && node.parts.all?(Prism::StringNode)
          return node.parts.map(&:unescaped).join
        end

        bad(node, "expected a plain string literal, got #{nodename(node)}") unless node.is_a?(Prism::StringNode)
        return node.unescaped
      end
      bad(node, "expected a symbol literal, got #{nodename(node)}") unless node.is_a?(Prism::SymbolNode)
      s = node.unescaped
      if want == :snake || want == :camel
        shape = want == :snake ? "snake_case" : "CamelCase"
        bad(node, "`:#{s}` must be #{shape}") unless s.match?(want == :snake ? SNAKE : CAMEL)
        bad(node, "`:#{s}` is a Rust keyword") if RUST_KW.include?(s)
        s
      else
        bad(node, "`:#{s}` is not one of #{want.map(&:inspect).join(' ')}", word: s, from: want) unless want.include?(s.to_sym)
        s.to_sym
      end
    end

    def block(node, sig)
      b = node.block
      if sig[:block].nil?
        bad(b, "`#{node.name}` takes no block") if b
        return nil
      end
      bad(node, "`#{node.name}` needs a do ... end block") unless b
      bad(b, "unsupported #{nodename(b)} (a literal block is required)") unless b.is_a?(Prism::BlockNode)
      bad(b.parameters, "`#{node.name}` block takes no parameters") if sig[:block] == :decls && b.parameters
      b
    end
  end
end
