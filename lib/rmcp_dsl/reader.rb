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
             "crates" => [], "items" => [], "item_lines" => [], "externs" => {}, "modules" => [], "subprocs" => [], "binding_fns" => [], "opaque_types" => [], "settings" => [], "prompts" => [], "resources" => [], "outputs" => [], "features" => [],
             "title" => kw[:title], "description" => kw[:description], "website_url" => kw[:website_url], "icon" => kw[:icon] }
      if kw.key?(:page_size)
        bad(nodes[0], "`page_size:` is how many items one page of tools, prompts, resources and resource templates holds; it must be at least 1") if kw[:page_size] < 1
        srv["page_size"] = kw[:page_size]
      end
      check_uri(nodes[0], "icon", kw[:icon]) if kw[:icon]
      check_uri(nodes[0], "website_url", kw[:website_url], web_only: true) if kw[:website_url]
      pending = []
      helper_nodes = []
      openapi_nodes = []
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
        when :setting then add_setting(n, p, k, srv)
        when :feature then add_feature(n, p, srv)
        when :openapi then openapi_nodes << [n, p, k]
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
          if k.key?(:auth_setting)
            bad(n, "`auth_setting:` only applies to `transport :http`") unless srv["transport"] == "http"
            srv["auth_setting"] = k[:auth_setting].to_s
            @transport_node = n
          end
          oauth = k.slice(:oauth_issuer, :oauth_audience, :oauth_resource)
          unless oauth.empty?
            bad(n, "`#{oauth.keys.first}:` only applies to `transport :http`") unless srv["transport"] == "http"
            bad(n, "`oauth_issuer:` and `oauth_audience:` go together, and `oauth_resource:` needs both") unless oauth.key?(:oauth_issuer) && oauth.key?(:oauth_audience)
            srv["oauth"] = oauth.to_h { |key, value| [key.to_s.delete_prefix("oauth_"), value.to_s] }
            @transport_node = n
          end
        end
      end
      bad(nodes[0], "missing `transport`") unless srv["transport"]
      srv["externs"].each do |fname, ext|
        next if ext["from"].nil? || srv["modules"].any? { |m| m["name"] == ext["from"] }

        bad(@extern_nodes.fetch(fname), "rust_fn `#{fname}` says from: :#{ext['from']}, but no rust_file has as: :#{ext['from']}")
      end
      @helper_async = resolve_helper_async(helper_nodes, srv)
      helper_nodes.each { |n, p, k, b| helper_decl(n, p, k, b, srv) }
      srv["user_helpers"] = @helper_table.values
      pending.each { |n, p, k, b| srv["tools"] << tool_decl(n, p, k, b, srv) }
      prompt_nodes.each { |n, p, k, b| srv["prompts"] << prompt_decl(n, p, k, b, srv) }
      resource_nodes.each { |n, p, k, b| srv["resources"] << resource_decl(n, p, k, b, srv) }
      openapi_nodes.each { |n, p, k| openapi_decl(n, p, k, srv) } # after the tools above, so a name taken twice is the generated one's
      check_tool_visibility(srv)
      resolve_completers(srv)
      check_resource_overlaps(srv)
      check_notifications(srv)
      lower_bindings(srv)
      srv["checked"] = (@flags["checked"] || {}).keys.sort
      srv["helpers"] = (@flags["helpers"] || {}).keys.sort
      check_http_auth(srv)
      check_http_oauth(srv)
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
      used_settings = @flags["used_settings"] || {}
      srv["settings"].each do |s|
        next if used_settings[s["name"]]

        bad(@setting_nodes.fetch(s["name"]), "setting `#{s['name']}` is declared but no body reads it; use setting(:#{s['name']}) in a tool, prompt or resource body, or remove it")
      end
      called_helpers = @flags["used_helpers"] || {}
      @helper_table.each_key do |hname|
        next if called_helpers[hname]

        bad(@helper_decls.fetch(hname), "helper `#{hname}` is declared but never called; call it from a tool body or a later helper, or remove it")
      end
      # A params struct that only appears as another struct's nested field, or as the element of a list of
      # objects, counts as used.
      referenced = ->(fields) { fields.map { |f| f["type"] }.filter_map { |t| CompositeTypes.nested_struct_name(t) } }
      used = srv["tools"].map { |t| t["params"] } + srv["prompts"].map { |t| t["params"] } + srv["resources"].filter_map { |t| t["params"] } +
             srv["params"].flat_map { |p| referenced.call(p["fields"]) }
      used_outputs = srv["tools"].filter_map { |t| t["output"] } +
                     srv["outputs"].flat_map { |p| referenced.call(p["fields"]) }
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

    MAX_OPENAPI_BYTES = 20_000_000
    HEADER_NAME = /\A[A-Za-z0-9!#$%&'*+.^_`|~-]+\z/

    # openapi "petstore.json", base_url: :api_url, auth_setting: :api_key, include_tags: ["pets"], exclude: ["deletePet"]
    # One tool per operation of the OpenAPI file beside this one, with the operation's parameters as fields, a `body`
    # field for a JSON request body, and the schema the document gives. A call makes the HTTP request and answers
    # {"status": ..., "body": ...} (a non-2xx status is an error result with the same text). See OpenApi.
    def openapi_decl(node, pos, kw, srv)
      rel = pos[0]
      unless rel.match?(/\.(json|ya?ml)\z/i) && !rel.start_with?("/") && !rel.include?("\0") && !rel.split("/").include?("..")
        bad(node, "openapi path must be relative, inside the DSL file's folder, without .., and end in .json, .yaml or .yml")
      end
      base_dir = File.realpath(File.dirname(File.expand_path(@path)))
      full = File.expand_path(rel, base_dir)
      bad(node, "openapi file not found: #{rel} (looked in #{base_dir})") unless File.file?(full)
      real = File.realpath(full)
      bad(node, "openapi file must stay inside #{base_dir}") unless real.start_with?(base_dir + File::SEPARATOR)
      bad(node, "openapi file is larger than #{MAX_OPENAPI_BYTES} bytes") if File.size(real) > MAX_OPENAPI_BYTES
      doc, plans = begin
        d = OpenApi.load(real)
        [d, OpenApi.plan(d, rel, include_tags: kw[:include_tags], exclude: kw[:exclude])]
      rescue CompileError => e
        bad(node, e.message)
      end
      base = openapi_base(node, kw, doc, srv)
      auth = openapi_auth(node, kw, srv)
      openapi_notices(node, rel, plans, doc, auth)
      register_openapi_runtime(srv)
      plans.each { |plan| openapi_tool(node, plan, base, auth, srv) }
    end

    # Where requests go: a setting that holds the address, or the first address the document lists (one without {variables}).
    def openapi_base(node, kw, doc, srv)
      if kw[:base_url]
        name = kw[:base_url].to_s
        openapi_setting(node, srv, name, "base_url:")
        return { "setting" => name }
      end
      url = doc.dig("servers", 0, "url")
      unless url.is_a?(String) && url.match?(%r{\Ahttps?://[^{}\s]+\z})
        bad(node, "the document gives no address to send requests to (its first server is #{url.inspect}; it needs an absolute http or https address without {variables}); add `base_url: :setting_name` naming a setting that holds the address")
      end
      { "url" => url }
    end

    def openapi_auth(node, kw, srv)
      unless kw[:auth_setting]
        bad(node, "`auth_header:` and `auth_scheme:` need `auth_setting:` (the setting that holds the key)") if kw[:auth_header] || kw[:auth_scheme]
        return nil
      end
      name = kw[:auth_setting].to_s
      openapi_setting(node, srv, name, "auth_setting:")
      header = kw[:auth_header] || "Authorization"
      bad(node, "`auth_header:` #{header.inspect} is not a valid HTTP header name") unless header.match?(HEADER_NAME)
      scheme = kw.key?(:auth_scheme) ? kw[:auth_scheme] : (header.casecmp?("Authorization") ? "Bearer" : nil)
      bad(node, "`auth_scheme:` is one word such as Bearer or Basic, got #{scheme.inspect}") if scheme && !scheme.match?(/\A[A-Za-z][A-Za-z0-9._-]*\z/)
      { "header" => header, "scheme" => scheme, "setting" => name }
    end

    # `transport :http, auth_setting: :name`: every request to /mcp must carry that setting's value as a bearer token.
    # The setting has to be a secret, so the token can never be printed or returned by a body.
    # `transport :http, oauth_issuer: :a, oauth_audience: :b`: every request to /mcp must carry a JWT access token that the
    # issuer signed for this audience. The issuer, the audience and the optional public URL (`oauth_resource:`) are
    # ordinary settings; none of them is a secret.
    def check_http_oauth(srv)
      oauth = srv["oauth"] or return
      bad(@transport_node, "`auth_setting:` and `oauth_issuer:` are two ways to authenticate /mcp; use one") if srv["auth_setting"]
      oauth.each do |key, name|
        openapi_setting(@transport_node, srv, name, "oauth_#{key}:")
        bad(@transport_node, "`oauth_#{key}:` names `#{name}`, which is a secret; the issuer, audience and URL are public, so drop `secret: true`") if srv["settings"].find { |s| s["name"] == name }["secret"]
      end
      { "jsonwebtoken" => "9", "ureq" => "2", "serde_json" => "1" }.each do |crate, version|
        srv["crates"] << { "name" => crate, "version" => version } unless srv["crates"].any? { |c| c["name"] == crate }
      end
    end

    def check_http_auth(srv)
      name = srv["auth_setting"] or return
      openapi_setting(@transport_node, srv, name, "auth_setting:")
      entry = srv["settings"].find { |s| s["name"] == name }
      bad(@transport_node, "`auth_setting:` needs `#{name}` to be `secret: true`, so the token cannot be printed or returned") unless entry["secret"]
    end

    def openapi_setting(node, srv, name, what)
      known = srv["settings"].map { |s| s["name"] }
      entry = srv["settings"].find { |s| s["name"] == name }
      bad(node, "`#{what}` names setting `#{name}`, which is not declared (declared: #{known.empty? ? 'none' : known.join(', ')}); add `setting :#{name}, env: \"...\"`", word: name, from: known) unless entry
      bad(node, "`#{what}` needs `#{name}` to always have a value, but it is `optional: true`; make it required or give it a `default:`") if entry["optional"]
      (@flags["used_settings"] ||= {})[name] = true
    end

    def openapi_notices(node, rel, plans, doc, auth)
      Notify.add(@path, node, "N-OPENAPI", "#{rel}: #{plans.size} tool(s): #{plans.map(&:name).join(', ')}")
      return if auth

      secured = plans.select { |pl| Array(pl.security).any? { |req| req.is_a?(Hash) && !req.empty? } }
      return if secured.empty?

      kinds = doc.dig("components", "securitySchemes").to_h.values.map { |s| s.is_a?(Hash) ? [s["type"], s["in"], s["name"], s["scheme"]].compact.join(" ") : nil }.compact
      Notify.add(@path, node, "W-OPENAPI-AUTH",
                 "#{secured.map(&:name).join(', ')} need authentication#{kinds.empty? ? '' : " (#{kinds.join('; ')})"}, but `auth_setting:` is not given, so requests go out without a key")
    end

    # What every generated tool needs: the JSON type of a request body, the HTTP client and the encoder.
    def register_openapi_runtime(srv)
      unless srv["opaque_types"].any? { |t| t["name"] == OpenApi::OpaqueName }
        CompositeTypes::Opaque.register(OpenApi::OpaqueName, "serde_json::Value", true)
        srv["opaque_types"] << { "name" => OpenApi::OpaqueName, "rust" => "serde_json::Value", "wire" => true }
      end
      { "ureq" => "2", "serde_json" => "1" }.each do |crate, version|
        srv["crates"] << { "name" => crate, "version" => version } unless srv["crates"].any? { |c| c["name"] == crate }
      end
      unless srv["items"].include?(OpenApi::HELPERS)
        srv["items"] << OpenApi::HELPERS
        srv["item_lines"] << nil
      end
    end

    def openapi_tool(node, plan, base, auth, srv)
      args_name = "#{plan.name.split('_').map(&:capitalize).join}Args"
      bad(node, "operation #{plan.method.upcase} #{plan.path}: the tool name `#{plan.name}` is already a tool of this server") if srv["tools"].any? { |t| t["name"] == plan.name }
      bad(node, "operation #{plan.method.upcase} #{plan.path}: the arguments would be called `#{args_name}`, which is already a params or output name") if (srv["params"] + srv["outputs"]).any? { |x| x["name"] == args_name }
      fields = plan.fields.map { |f| openapi_field(node, plan, f, srv) }
      prm = { "name" => args_name, "fields" => fields, "line" => node.location.start_line }
      srv["params"] << prm
      begin
        check_input_schema(node, plan.schema, prm) # the schema and the fields come from one place; this keeps them honest
      rescue CompileError => e
        raise CompileError, "#{e.message} (this is a bug in the openapi reader: operation #{plan.method.upcase} #{plan.path})"
      end
      decl = { "name" => plan.name, "description" => plan.description, "params" => args_name,
               "body" => OpenApi.body_ir(plan, base: base, auth: auth), "line" => node.location.start_line,
               "input_schema" => plan.schema }
      decl["annotations"] = plan.annotations
      srv["tools"] << decl
    end

    def openapi_field(node, plan, f, srv)
      field = { "name" => f["name"], "type" => f["type"] }
      field["description"] = f["description"] if f["description"]
      opts = {}
      opts[:optional] = true if f["optional"]
      %w[min max exclusive_min exclusive_max multiple_of min_length max_length enum min_items max_items format].each { |k| opts[k.to_sym] = f[k] if f.key?(k) }
      field_options(node, field, opts, srv)
      field
    rescue CompileError => e
      raise CompileError, "#{e.message} (operation #{plan.method.upcase} #{plan.path}, argument `#{f['name']}`)"
    end

    # setting :api_key, env: "API_KEY", secret: true. A setting is read from its environment variable once, when the
    # server starts; a required one that is missing (or empty) stops the server with a message naming the variable, so a
    # misconfigured server never answers a call. A body reads it with setting(:api_key). A secret can only be handed to a
    # binding or rust_fn function (the body language refuses to print or return it), and is never written to a message.
    def add_setting(node, pos, kw, srv)
      name = pos[0]
      bad(node, "duplicate setting `#{name}`") if srv["settings"].any? { |s| s["name"] == name }
      bad(node, "`env:` is an environment variable name in capitals, such as \"API_KEY\", got #{kw[:env].inspect}") unless kw[:env].match?(/\A[A-Z][A-Z0-9_]*\z/)
      dup = srv["settings"].find { |s| s["env"] == kw[:env] }
      bad(node, "setting `#{dup['name']}` already reads #{kw[:env]}; one variable, one setting") if dup
      bad(node, "`optional: false` is the default; leave `optional:` out") if kw[:optional] == false
      bad(node, "`secret: false` is the default; leave `secret:` out") if kw[:secret] == false
      bad(node, "a setting with a `default:` is never missing, so `optional: true` has nothing to add") if kw.key?(:default) && kw[:optional]
      bad(node, "a secret has no `default:`: a key written in the file is not a secret") if kw[:secret] && kw.key?(:default)
      bad(node, "a secret is either there or the server does not start, so it cannot be `optional:`") if kw[:secret] && kw[:optional]
      entry = { "name" => name, "env" => kw[:env] }
      %i[description default].each { |k| entry[k.to_s] = kw[k] if kw.key?(k) }
      entry["optional"] = true if kw[:optional]
      entry["secret"] = true if kw[:secret]
      srv["settings"] << entry
      (@setting_nodes ||= {})[name] = node
      (@flags["settings"] ||= {})[name] = entry
    end

    # feature :logging. A server-level gate: it declares that the server uses the feature, which is what puts
    # a gated body built-in (today only `log`) in scope and advertises the capability. Declaring a feature the
    # pinned rmcp deprecates is allowed and emits N-DEPRECATED-FEATURE (a notice, never a failure).
    def add_feature(node, pos, srv)
      name = pos[0].to_sym
      entry = Features.get(name) or bad(node, "unknown feature `:#{name}` (known: #{Features.names.map(&:inspect).join(', ')})")
      bad(node, "duplicate `feature :#{name}`") if srv["features"].any? { |f| f["name"] == name.to_s }
      unless entry[:provided]
        bad(node, "feature `:#{name}` is not provided by the pinned rmcp #{RMCP_VERSION} (#{entry[:reference]}); remove `feature :#{name}`")
      end
      feature = { "name" => name.to_s, "provided" => entry[:provided], "reference" => entry[:reference] }
      feature["deprecated"] = entry[:deprecated] if entry[:deprecated]
      srv["features"] << feature
      (@flags["features"] ||= {})[name.to_s] = true
      return unless (sep = entry[:deprecated])

      Notify.add(@path, node, "N-DEPRECATED-FEATURE",
                 "feature `:#{name}` is deprecated by #{sep} and will be removed from a future rmcp; " \
                 "rmcp #{RMCP_VERSION} still provides it, so the emitted call is scoped with #[allow(deprecated)]")
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
      srv["item_lines"] << item_body_line(node) # the DSL line the snippet text starts on, so a Rust diagnostic can be mapped back
      Notify.add(@path, node, "N-RUST-INJECTED",
                 "#{code.lines.size} line(s) of injected Rust; the compiler does not check them (cargo does)")
    end

    # The first line of a `rust_item` string: a heredoc body starts on the line after the call.
    def item_body_line(node)
      arg = node.arguments&.arguments&.first
      if arg.respond_to?(:content_loc) && arg.content_loc then arg.content_loc.start_line
      elsif arg.respond_to?(:parts) && arg.parts.first then arg.parts.first.location.start_line # a multi-line <<~ is parts, one per line
      else node.location.start_line
      end
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
      refuse_subproc_async(node, kw[:async])
      register_subproc(node, pos[0], kw[:program], kw[:argv] || [], kw[:args], (kw[:pass] || :argv).to_s, srv, "command")
    end

    def add_script(node, pos, kw, srv)
      refuse_subproc_async(node, kw[:async])
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
      srv["externs"][pos[0]] = { "args" => kw[:args], "returns" => kw[:returns].to_s, "from" => kw[:from],
                                 "async" => kw[:async] ? true : false,
                                 "async_reason" => (kw[:async] ? "is declared `async: true`" : nil) }
    end

    # Async is inferred: a function is async iff it calls an async function. A helper is async when its
    # body calls an async helper, rust_fn or binding function; the result is the fixpoint over the
    # helper-call graph. A cycle among async helpers is refused (an async function that calls itself
    # would need `Box::pin`, which the DSL does not emit). A helper may only call helpers declared above
    # it, so a real cycle is unreachable from a well-formed file; the guard stays as a backstop.
    def resolve_helper_async(helper_nodes, srv)
      names = helper_nodes.map { |_n, pos, _k, _b| pos[0] }
      node_for = helper_nodes.to_h { |n, pos, _k, _b| [pos[0], n] }
      edges = {}
      direct = {}
      helper_nodes.each do |_n, pos, _kw, blk|
        name = pos[0]
        edges[name] ||= []
        walk_nodes(blk.body) do |n|
          next unless n.is_a?(Prism::CallNode)

          if n.receiver.nil? && names.include?(n.name.to_s)
            edges[name] << n.name.to_s unless edges[name].include?(n.name.to_s)
          elsif n.receiver.nil? && n.name == :rust
            sym = n.arguments&.arguments&.first
            direct[name] = true if sym.is_a?(Prism::SymbolNode) && srv["externs"][sym.unescaped]&.dig("async")
          elsif n.receiver.is_a?(Prism::ConstantReadNode)
            fn = @binding_modules[n.receiver.name.to_s]&.fns&.[](n.name.to_s)
            direct[name] = true if fn&.async
          end
        end
      end
      async = names.to_h { |n| [n, direct[n] || false] }
      changed = true
      while changed
        changed = false
        names.each do |n|
          next if async[n]

          if edges[n].any? { |m| async[m] }
            async[n] = true
            changed = true
          end
        end
      end
      cycle = async_helper_cycle(names, edges, async)
      if cycle
        path = cycle.join(" -> ")
        bad(node_for.fetch(cycle[0]),
            "helper `#{cycle[0]}` is async and is part of a recursive helper cycle (#{path}); " \
            "an async function in a cycle would need Box::pin, which the DSL does not emit. Break the cycle.")
      end
      async
    end

    # Every node under `node`, for the async helper scan.
    def walk_nodes(node, &blk)
      return unless node

      yield node
      node.compact_child_nodes.each { |c| walk_nodes(c, &blk) }
    end

    # The first cycle among async helpers (`a -> b -> ... -> a`), or nil.
    def async_helper_cycle(names, edges, async)
      state = {}
      stack = []
      cycle = nil
      visit = lambda do |n|
        return if cycle

        state[n] = :visiting
        stack.push(n)
        edges[n].each do |m|
          next unless names.include?(m) && async[m]

          if state[m] == :visiting
            cycle = stack[stack.index(m)..] + [m]
            return
          elsif state[m].nil?
            visit.call(m)
            return if cycle
          end
        end
        stack.pop
        state[n] = :done
      end
      names.each { |n| visit.call(n) if async[n] && state[n].nil? }
      cycle
    end

    def refuse_subproc_async(node, async)
      return unless async

      bad(node, "`async: true` is not supported on a subprocess: cmd_fn and script_fn run a blocking " \
                "std::process::Command, so the call would block the async runtime; async subprocesses are planned for a later wave")
    end

    def refuse_helper_async(node, name, async)
      return unless async

      bad(node, "`async: true` is not supported on helper `#{name}`: async is inferred from the body, " \
                "so remove `async: true` and call an async rust_fn or binding instead")
    end

    NUMERIC_TYPES = %w[i32 i64 f64].freeze

    # Options on a `field`: optional, and JSON schema constraints the generated server also enforces.
    # Each option has to make sense for the field's type, so `min:` on a string is refused here.
    LIST_TYPES = %w[string_list i64_list f64_list].freeze

    def field_options(node, field, opts, srv, pool = srv["params"], label = "params")
      type = field["type"]
      if opts.key?(:complete)
        bad(node, "`complete:` applies to :string fields, not :#{type}") if type != "string"
        bad(node, "`complete:` and `enum:` cannot be combined; both decide the completion values") if opts.key?(:enum)
        bad(node, "`complete:` only applies to a params field used by a prompt or resource template, not an output field") if label != "params"
        field["complete"] = opts[:complete]
      end
      if (oname = CompositeTypes.object_list_name(type)) # a list of another params struct, declared above
        bad(node, "#{label} `#{oname}` is not declared above this field; declare it first") unless pool.any? { |x| x["name"] == oname }
        bad(node, "`default:` does not apply to a list of objects") if opts.key?(:default)
        field["optional"] = true if opts[:optional]
        stray = opts.keys - %i[description optional min_items max_items]
        bad(node, "`#{stray.first}:` does not apply to a list of objects") unless stray.empty?
        %i[min_items max_items].each { |key| field[key.to_s] = opts[key] if opts.key?(key) }
        bad(node, "`min_items:` is above `max_items:`") if field["min_items"] && field["max_items"] && field["min_items"] > field["max_items"]
        return
      end
      if type.match?(CAMEL) # a nested object: the other struct must be declared above, so schemas cannot loop
        bad(node, "#{label} `#{type}` is not declared above this field; declare it first") unless pool.any? { |x| x["name"] == type }
        if opts.key?(:default)
          bad(node, "`default:` and `optional:` cannot be combined (a field with a default is always present)") if opts[:optional]
          bad(node, "`default:` does not apply to a nested object field")
        end
        field["optional"] = true if opts[:optional]
        stray = opts.keys - %i[description optional]
        bad(node, "`#{stray.first}:` does not apply to a nested object field") unless stray.empty?
        return
      end
      if (mname = CompositeTypes.object_map_name(type)) # a map of another params struct, declared above
        bad(node, "#{label} `#{mname}` is not declared above this field; declare it first") unless pool.any? { |x| x["name"] == mname }
      end
      field["optional"] = true if opts[:optional]
      %i[min max exclusive_min exclusive_max multiple_of].each do |key|
        next unless opts.key?(key)

        bad(node, "`#{key}:` applies to numeric fields, not :#{type}") unless NUMERIC_TYPES.include?(type)
        if key == :multiple_of
          bad(node, "`multiple_of:` applies to :i32 and :i64 fields, not :#{type}") if type == "f64"
          bad(node, "`multiple_of:` must be a positive integer") unless opts[key].is_a?(Integer) && opts[key].positive?
        else
          bad(node, "`#{key}:` must be an integer for an :#{type} field") if type != "f64" && !opts[key].is_a?(Integer)
          bad(node, "`#{key}:` does not fit in an :i32 field") if type == "i32" && !(-2**31..2**31 - 1).cover?(opts[key])
        end
        field[key.to_s] = opts[key]
      end
      bad(node, "`min:` is above `max:`") if field["min"] && field["max"] && field["min"] > field["max"]
      bad(node, "`min:` and `exclusive_min:` both set a lower bound; keep one") if field["min"] && field["exclusive_min"]
      bad(node, "`max:` and `exclusive_max:` both set an upper bound; keep one") if field["max"] && field["exclusive_max"]
      bad(node, "`exclusive_min:` is not below `exclusive_max:`") if field["exclusive_min"] && field["exclusive_max"] && field["exclusive_min"] >= field["exclusive_max"]
      %i[min_length max_length pattern enum format].each do |key|
        bad(node, "`#{key}:` applies to :string fields, not :#{type}") if opts.key?(key) && type != "string"
      end
      %i[min_items max_items].each do |key|
        next unless opts.key?(key)

        bad(node, "`#{key}:` applies to list fields, not :#{type}") unless LIST_TYPES.include?(type) || CompositeTypes.map_field_text?(type)
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
      bad(node, "`default:` is not above `exclusive_min:`") if field["exclusive_min"] && value <= field["exclusive_min"]
      bad(node, "`default:` is not below `exclusive_max:`") if field["exclusive_max"] && value >= field["exclusive_max"]
      bad(node, "`default:` is not a multiple of `multiple_of:`") if field["multiple_of"] && value % field["multiple_of"] != 0
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

    def json_value(node) = JsonLiteral.value(node, self, what: "`meta:`")

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
      if inside == :list
        bad(node, "`list(...)` cannot hold `#{node.name}(...)` yet: lists of maps or lists are not supported")
      end
      inner = field_type_expr(args[0], inside: node.name)
      if node.name == :list
        return "list(#{inner})" if inner.match?(CAMEL)

        return { "string" => "string_list", "i64" => "i64_list", "f64" => "f64_list" }.fetch(inner) do
          bad(args[0], "`list(:#{inner})` is not supported yet; lists hold :string, :i64 or :f64")
        end
      end
      # map(<inner>): a scalar or list value type, a nested object, or a map of a scalar value type.
      return "map(#{inner})" if CompositeTypes::VALUES.key?(inner)
      return "map(#{inner})" if inner.match?(CAMEL)
      if inner.start_with?("map(")
        if (m = inner.match(/\Amap\(([A-Z]\w*)\)\z/))
          bad(args[0], "`map(map(:#{m[1]}))` is not supported yet: maps of maps of objects are not supported")
        end
        unless inner.match?(/\Amap\((?:string|i64|f64|bool|string_list|i64_list|f64_list)\)\z/)
          bad(args[0], "`map(#{inner})` is not supported yet: maps nest one level, as in map(map(:i64))")
        end
        return "map(#{inner})"
      end
      if inner.match?(/\Alist\([A-Z]\w*\)\z/)
        bad(args[0], "`map(#{inner})` is not supported yet: maps of lists of objects are not supported")
      end

      hint = case inner
             when "i32" then "map values use :i64 for integers"
             else "map values can be :string, :i64, :f64, :bool, list(:string), list(:i64), list(:f64), a params object, or map(<value>)"
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
    DECLARATION_SKIP = %i[field helper output body complete].freeze

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
        (@field_nodes ||= {})["#{pos[0]}:#{field['name']}"] = n
        note_field(n, field)
        fields << field
      end
      bad(node, "params `#{pos[0]}` needs at least one `field`") if fields.empty?
      { "name" => pos[0], "fields" => fields, "line" => node.location.start_line }
    end

    # Names a helper cannot take: they would collide with something the generated crate defines, or with a
    # request-context built-in a tool body reads (Body::CONTEXT_BUILTINS) or a statement built-in such as
    # `progress` or `log`.
    RESERVED_HELPERS = (%w[main check run_subprocess arith_error str_to_i str_to_int result progress hide_tool show_tool elicit log roots sample] +
                        Body::CONTEXT_BUILTINS.keys.map(&:to_s)).freeze

    # helper :guard, args: [:string], returns: :string do |url| ... end. A helper is compiled in declaration
    # order and may only call helpers declared above it, so recursion cannot happen. Types are never inferred.
    # A nil-able argument (:string?) is Option<T> in Rust and follows the nil-able rules in the body.
    def helper_decl(node, pos, kw, blk, srv)
      name = pos[0]
      refuse_helper_async(node, name, kw[:async])
      bad(node, "duplicate helper `#{name}`") if @helper_table.key?(name)
      bad(node, "helper `#{name}` has the same name as a rust_fn, cmd_fn or script_fn") if srv["externs"].key?(name)
      bad(node, "`#{name}` is reserved; pick another helper name") if RESERVED_HELPERS.include?(name) || name.start_with?("__")
      arg_syms = kw[:args].map(&:to_sym)
      arg_types = arg_syms.map { |s| HELPER_TYPES.fetch(s) }
      ret = HELPER_TYPES.fetch(kw[:returns])
      kw_specs = kw[:kw] || {}
      parsed = helper_params(blk, node)
      names = parsed[:pos]
      bad(node, "helper `#{name}` declares #{arg_types.size} argument type(s) but its block takes #{names.size}") unless names.size == arg_types.size
      kw_specs.each_key { |k| bad(node, "keyword parameter `#{k}:` has the same name as a positional parameter") if names.include?(k.to_s) }
      kw_body = []
      kw_record = []
      kw_specs.each do |kname, (tsym, required)|
        found = parsed[:kw].find { |p| p[:name] == kname.to_s } or
          bad(node, "helper `#{name}` declares keyword `#{kname}:` but its block has no such parameter")
        ir = HELPER_TYPES.fetch(tsym)
        if required
          bad(found[:node], "keyword parameter `#{kname}:` is required in `kw:` but the block gives it a default") if found[:default]
          kw_record << { "name" => kname.to_s, "type" => ir.to_s, "required" => true }
        else
          bad(found[:node], "keyword parameter `#{kname}:` is optional in `kw:` so the block must give it a literal default") unless found[:default]
          dflt = helper_default(found[:default], tsym, kname)
          kw_record << { "name" => kname.to_s, "type" => ir.to_s, "required" => false, "default" => dflt }
        end
        kw_body << [kname.to_s, ir, found[:node]]
      end
      parsed[:kw].each do |p|
        next if kw_specs.key?(p[:name].to_sym)

        bad(p[:node], "helper `#{name}` block has keyword parameter `#{p[:name]}:` that `kw:` does not declare")
      end
      body = Body.new(@path, { "fields" => [] }, @regexes, srv["externs"], @flags, "helper `#{name}`", @binding_modules,
                      @helper_table.dup).lower_helper(blk, names, arg_types, ret, kw_body)
      @helper_decls[name] = node
      async = body["uses_async"]
      reason = async ? body["async_reason"] : nil
      @types&.add(node.location, "helper", "(#{arg_types.map { |t| TypeNames.display(t) }.join(", ")}) -> #{TypeNames.display(ret)}",
                  name: name, extra: async ? { async: true, async_reason: reason } : nil)
      @helper_table[name] = { "name" => name, "args" => names.zip(arg_types.map(&:to_s)), "kw" => kw_record,
                              "returns" => ret.to_s, "body" => body, "async" => async, "async_reason" => reason,
                              "line" => node.location.start_line }
    end

    # The positional and keyword parameters a helper block declares. Positional parameters come first, then
    # keyword ones: a required keyword has no default, an optional one a literal default. Optional or post
    # positional parameters, rest/keyword-rest/block parameters and block-locals are refused.
    def helper_params(blk, node)
      ps = blk.parameters
      return { pos: [], kw: [] } unless ps

      bad(ps, "unsupported #{nodename(ps)} as helper parameters") unless ps.is_a?(Prism::BlockParametersNode)
      bad(ps, "block-local variables are not allowed") unless ps.locals.empty?
      pn = ps.parameters
      return { pos: [], kw: [] } unless pn

      extra = [pn.optionals, pn.posts].any? { |x| !x.empty? } || pn.rest || pn.keyword_rest || pn.block
      bad(pn, "only required positional parameters and keyword parameters are allowed") if extra
      seen = []
      pos = pn.requireds.map do |r|
        bad(r, "unsupported #{nodename(r)} as a helper parameter") unless r.is_a?(Prism::RequiredParameterNode)
        bad(r, "parameter `#{r.name}` must be snake_case and not a Rust keyword") if !r.name.to_s.match?(SNAKE) || RUST_KW.include?(r.name.to_s)
        bad(r, "duplicate parameter `#{r.name}`") if seen.include?(r.name.to_s)
        seen << r.name.to_s
        r.name.to_s
      end
      kw = pn.keywords.map do |k|
        unless k.is_a?(Prism::RequiredKeywordParameterNode) || k.is_a?(Prism::OptionalKeywordParameterNode)
          bad(k, "unsupported #{nodename(k)} as a helper keyword parameter")
        end
        bad(k, "parameter `#{k.name}` must be snake_case and not a Rust keyword") if !k.name.to_s.match?(SNAKE) || RUST_KW.include?(k.name.to_s)
        bad(k, "duplicate parameter `#{k.name}`") if seen.include?(k.name.to_s)
        seen << k.name.to_s
        { name: k.name.to_s, node: k, default: k.is_a?(Prism::OptionalKeywordParameterNode) ? k.value : nil }
      end
      { pos: pos, kw: kw }
    end

    # A keyword parameter's default must be a literal of its declared type; a nil default is allowed only for
    # a nil-able type. Returns the Ruby literal the IR carries (nil means the default is nil, i.e. Rust None).
    def helper_default(node, tsym, kname)
      literals = [Prism::StringNode, Prism::IntegerNode, Prism::FloatNode, Prism::TrueNode, Prism::FalseNode,
                  Prism::ArrayNode, Prism::NilNode]
      bad(node, "keyword parameter `#{kname}:` needs a literal default, got #{nodename(node)}") unless literals.any? { |k| node.is_a?(k) }
      nilable = tsym.to_s.end_with?("?")
      if node.is_a?(Prism::NilNode)
        bad(node, "keyword parameter `#{kname}:` is not nil-able, so its default cannot be nil") unless nilable
        return nil
      end
      base = nilable ? Body::OPT.fetch(HELPER_TYPES.fetch(tsym)) : HELPER_TYPES.fetch(tsym)
      case base
      when :string
        bad(node, "the default for keyword `#{kname}:` must be a string literal, got #{nodename(node)}") unless node.is_a?(Prism::StringNode)
        node.unescaped
      when :i32, :i64
        bad(node, "the default for keyword `#{kname}:` must be an integer literal, got #{nodename(node)}") unless node.is_a?(Prism::IntegerNode)
        node.value
      when :f64
        bad(node, "the default for keyword `#{kname}:` must be a number literal, got #{nodename(node)}") unless node.is_a?(Prism::IntegerNode) || node.is_a?(Prism::FloatNode)
        node.value
      when :bool
        bad(node, "the default for keyword `#{kname}:` must be true or false, got #{nodename(node)}") unless node.is_a?(Prism::TrueNode) || node.is_a?(Prism::FalseNode)
        node.is_a?(Prism::TrueNode)
      when :strs
        bad(node, "the default for keyword `#{kname}:` must be an array of string literals, got #{nodename(node)}") unless node.is_a?(Prism::ArrayNode) && node.elements.all? { |el| el.is_a?(Prism::StringNode) }
        node.elements.map(&:unescaped)
      when :i64s
        bad(node, "the default for keyword `#{kname}:` must be an array of integer literals, got #{nodename(node)}") unless node.is_a?(Prism::ArrayNode) && node.elements.all? { |el| el.is_a?(Prism::IntegerNode) }
        node.elements.map(&:value)
      when :f64s
        bad(node, "the default for keyword `#{kname}:` must be an array of number literals, got #{nodename(node)}") unless node.is_a?(Prism::ArrayNode) && node.elements.all? { |el| el.is_a?(Prism::IntegerNode) || el.is_a?(Prism::FloatNode) }
        node.elements.map(&:value)
      else
        bad(node, "keyword parameter `#{kname}:` of type :#{tsym} cannot have a literal default")
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
      complete_body = nil
      each_child(blk, :prompt) do |n, p, _k, b|
        if n.name == :complete
          bad(n, "a prompt has at most one `complete` block") if complete_body
          complete_body = Body.new(@path, { "fields" => [] }, @regexes, srv["externs"], @flags,
                                   "complete block of prompt `#{pos[0]}`", @binding_modules, @helper_table).lower_helper(b, ["arg", "typed"], [:string, :string], :strs)
          next
        end
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
      check_complete_mix(node, "prompt `#{pos[0]}`", prm, complete_body)
      decl["complete_body"] = complete_body if complete_body
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
      complete_body = nil
      each_child(blk, :resource) do |n, _p, _k, b|
        if n.name == :complete
          bad(n, "a resource has at most one `complete` block") if complete_body
          complete_body = Body.new(@path, { "fields" => [] }, @regexes, srv["externs"], @flags,
                                   "complete block of resource `#{pos[0]}`", @binding_modules, @helper_table).lower_helper(b, ["arg", "typed"], [:string, :string], :strs)
          next
        end
        bad(n, "duplicate `body`") if body
        check_resource_size(node, kw[:size], b) if kw[:size]
        bad(b.parameters, "a resource body takes no parameters (give the uri `{placeholders}` and `params:` to pass it values)") if b.parameters && !prm
        body = Body.new(@path, prm || { "fields" => [] }, @regexes, srv["externs"], @flags, "resource `#{pos[0]}`", @binding_modules, @helper_table,
                        srv["params"], mime_type: kw[:mime_type]).lower(b)
      end
      bad(node, "resource `#{pos[0]}` needs a `body`") unless body
      if complete_body && prm.nil?
        bad(node, "a `complete` block only applies to a resource template (a `uri:` with {placeholders} and `params:`); `#{pos[0]}` has a fixed uri")
      end
      check_complete_mix(node, "resource `#{pos[0]}`", prm, complete_body)
      template = {}
      if prm
        regex_id = "RE_#{@regexes.size + 1}"
        @regexes << { "id" => regex_id, "pattern" => template_pattern(segments) }
        template = { "template" => true, "params" => prm["name"], "vars" => vars, "regex_id" => regex_id }
      end
      { "name" => pos[0], "uri" => kw[:uri], "description" => kw[:description], "mime_type" => kw[:mime_type], **template,
        "title" => kw[:title], "icon" => kw[:icon], "meta" => kw[:meta], "audience" => kw[:audience], "priority" => kw[:priority],
        "size" => kw[:size], "body" => body, "complete_body" => complete_body, "line" => node.location.start_line }
    end

    # `size:` is what clients show as the resource's size and use to estimate how much of a model's context it takes
    # (the specification: the size of the raw content in bytes, before base64 or tokenization). When the body is a
    # plain string, the compiler knows that size and refuses a number that is wrong; for a computed body it cannot,
    # so the number is the author's word.
    # `complete:` on a field names a helper declared with one :string argument and a :string_list result. MCP
    # completion applies only to prompt arguments and resource-template arguments, so the field's params must be
    # used by one of those (a tool's arguments are not a Reference and are never completed).
    def resolve_completers(srv)
      prompt_params = srv["prompts"].map { |p| p["params"] }
      template_params = srv["resources"].select { |r| r["template"] }.map { |r| r["params"] }
      srv["params"].each do |prm|
        pname = prm["name"]
        prm["fields"].each do |field|
          name = field["complete"] or next
          fname = field["name"]
          node = (@field_nodes || {})["#{pname}:#{fname}"]
          unless prompt_params.include?(pname) || template_params.include?(pname)
            bad(node, "`complete:` applies to prompt arguments and resource-template arguments; params `#{pname}` is used only by a tool, so MCP does not complete tool arguments")
          end
          if srv["externs"].key?(name)
            bad(node, "`complete: :#{name}` names a rust_fn, cmd_fn or script_fn, not a helper; a completer must be a helper with one :string argument returning :string_list")
          end
          helper = @helper_table[name] or
            bad(node, "no helper `#{name}` declared for `complete:`; declare `helper :#{name}, args: [:string], returns: :string_list`", word: name, from: @helper_table.keys)
          args = helper["args"].map { |_, t| ":#{t}" }
          unless helper["args"].size == 1 && helper["args"][0][1] == "string" && helper["returns"] == "strs" && helper["kw"].to_a.empty?
            bad(node, "helper `#{name}` takes (#{args.join(", ")}) and returns :#{helper["returns"]}; a completer takes one :string argument and returns :string_list")
          end
          (@flags["used_helpers"] ||= {})[name] = true
        end
      end
    end

    # A `complete do |arg, typed| ... end` block answers for every argument of its reference, so a field-level
    # completion (`complete:` or `enum:`) on the same reference would be dead; refuse the mix rather than
    # silently ignoring one of them.
    def check_complete_mix(node, label, prm, complete_body)
      return unless complete_body && prm

      field = prm["fields"].find { |f| f["complete"] || f["enum"] }
      return unless field

      what = field["complete"] ? "`complete:`" : "`enum:`"
      bad(node, "#{label} has a `complete` block and #{what} on field `#{field["name"]}`; both complete the same arguments, so keep only one")
    end

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
      decl["input_schema"] = check_input_schema(node, kw[:input_schema], prm) if kw[:input_schema]
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

    # `input_schema:` replaces the JSON Schema the tool publishes for its arguments (for a schema written by hand or
    # taken from somewhere else, such as an OpenAPI operation). The server still reads and checks the arguments through
    # the params fields, so the schema may not promise a different shape than they accept: every field needs a property
    # of a matching type, there are no properties for things that are not fields, and `required` is exactly the fields
    # that have no default and are not optional.
    SCHEMA_TYPES = { "string" => %w[string], "i32" => %w[integer], "i64" => %w[integer], "f64" => %w[number integer],
                     "bool" => %w[boolean], "string_list" => %w[array], "i64_list" => %w[array], "f64_list" => %w[array] }.freeze

    def schema_literal(node)
      bad(node, "`input_schema:` is a JSON Schema object written as a literal, such as { \"type\" => \"object\", \"properties\" => { ... } }, got #{nodename(node)}") unless node.is_a?(Prism::HashNode)
      JsonLiteral.value(node, self, what: "`input_schema:`")
    end

    def check_input_schema(node, schema, prm)
      bad(node, "`input_schema:` must say `\"type\" => \"object\"` (a tool takes one object of arguments)") unless schema["type"] == "object"
      props = schema["properties"]
      bad(node, "`input_schema:` needs `\"properties\"`, a hash with one entry per field of params `#{prm['name']}`") unless props.is_a?(Hash)
      fields = prm["fields"]
      names = fields.map { |f| f["name"] }
      fields.each do |f|
        prop = props[f["name"]]
        bad(node, "`input_schema:` has no property for field `#{f['name']}` of params `#{prm['name']}`; the server still reads it") if prop.nil?
        check_schema_property(node, f, prop)
      end
      (props.keys - names).each do |extra|
        bad(node, "`input_schema:` has a property `#{extra}` that is not a field of params `#{prm['name']}` (fields: #{names.join(', ')}); the server would ignore what a client sent",
            word: extra, from: names)
      end
      required = schema["required"] || []
      bad(node, "`input_schema:` `required` is a list of field names") unless required.is_a?(Array) && required.all?(String)
      fields.each do |f|
        optional = f["optional"] || f.key?("default")
        if optional && required.include?(f["name"])
          bad(node, "`input_schema:` lists `#{f['name']}` as required, but the field is #{f['optional'] ? 'optional' : 'defaulted'}, so a client may leave it out")
        elsif !optional && !required.include?(f["name"])
          bad(node, "`input_schema:` does not list `#{f['name']}` in `required`, but the server needs it, so a client that leaves it out gets an error")
        end
      end
      (required - names).each { |extra| bad(node, "`input_schema:` requires `#{extra}`, which is not a field of params `#{prm['name']}`") }
      schema
    end

    def check_schema_property(node, field, prop)
      bad(node, "`input_schema:` property `#{field['name']}` is a hash such as { \"type\" => \"string\" }") unless prop.is_a?(Hash)
      type = prop["type"]
      return if type.nil? # a $ref or anyOf: nothing to compare
      return if field["type"].match?(CAMEL) || CompositeTypes.object_list?(field["type"]) || field["type"].match?(CompositeTypes::OPAQUE_FIELD) || CompositeTypes.map_field_text?(field["type"]) && Array(type).include?("object")

      want = SCHEMA_TYPES[field["type"]] || ["object"]
      return if (Array(type) & want).any?

      bad(node, "`input_schema:` says property `#{field['name']}` is #{Array(type).join(' or ')}, but the field is :#{field['type']} (#{want.join(' or ')})")
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

    # hide_tool/show_tool name one of the tools this server compiles. Every tool is known once the whole
    # file is read (openapi tools included), so a name that is not one is refused here rather than at run time.
    def check_tool_visibility(srv)
      refs = @flags["tool_visibility_refs"] || []
      return if refs.empty?

      names = srv["tools"].map { |t| t["name"] }
      refs.each do |ref|
        next if names.include?(ref["name"])

        bad(ref["node"],
            "`#{ref["builtin"]}` names `#{ref["name"]}`, which is not a tool of this server#{names.empty? ? "" : " (tools: #{names.join(", ")})"}",
            word: ref["name"], from: names)
      end
    end

    # Once every resource is declared: each `updates:` uri has to be one a resource serves (a fixed uri, or a template
    # that the uri with its placeholders filled matches), and `resource_list_changed:` needs resources to change.
    def check_notifications(srv)
      shapes = srv["resources"].map do |res|
        segs = parse_uri_template(@resource_nodes.fetch(res["name"]), res["uri"])
        [res, Regexp.new(template_pattern(segs))]
      end
      srv["tools"].each do |tool|
        node = (@tool_nodes || {})[tool["name"]] or next # a tool made from an OpenAPI document declares neither
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
      return schema_literal(node) if want == :schema
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
      if want == :helper_kw
        bad(node, "expected a hash literal `{ name: [type, required] }`, got #{nodename(node)}") unless node.is_a?(Prism::HashNode)
        out = {}
        node.elements.each do |el|
          bad(el, "unsupported #{nodename(el)} in `kw:` (use `name: [type, true]`)") unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
          k = el.key.unescaped
          bad(el, "keyword parameter `#{k}` must be snake_case and not a Rust keyword") if !k.match?(SNAKE) || RUST_KW.include?(k)
          bad(el, "duplicate keyword parameter `#{k}`") if out.key?(k.to_sym)
          arr = el.value
          bad(el, "keyword parameter `#{k}:` needs `[type, required]`, got #{nodename(arr)}") unless arr.is_a?(Prism::ArrayNode) && arr.elements.size == 2
          ty = value(arr.elements[0], HELPER_TYPES.keys)
          req = value(arr.elements[1], :bool)
          out[k.to_sym] = [ty, req]
        end
        return out
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
