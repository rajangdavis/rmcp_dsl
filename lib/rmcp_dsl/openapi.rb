# frozen_string_literal: true

require "json"
require "yaml"

module RmcpDsl
  # The `openapi "spec.json"` call: a compile-time read of an OpenAPI 3.0 or 3.1 document (JSON or YAML) that plans one
  # tool per operation. Nothing here knows about Prism or Rust; the reader turns a plan into declarations and the emitter
  # writes the request. Every mistake in the document is a CompileError that names the operation and says what to do.
  #
  # What a plan holds, for each operation:
  #   name         the tool name: operationId in snake_case, or method + path when there is none
  #   description  summary and description of the operation
  #   fields       the tool's arguments, in the shape of a params field: path, query and header parameters, then `body`
  #   schema       the JSON Schema the tool publishes (input_schema), with every $ref bundled under $defs
  #   request      how a call becomes an HTTP request: method, path template, and where each field goes
  module OpenApi
    METHODS = %w[get put post delete options head patch].freeze
    SAFE = %w[get head options].freeze
    IDEMPOTENT = %w[get head options put delete].freeze
    PARAM_IN = %w[path query header].freeze
    JSON_TYPE = /\Aapplication\/(?:[\w.+-]*\+)?json\z/

    Plan = Struct.new(:name, :id, :description, :method, :path, :annotations, :fields, :schema, :request, :tags, :security, keyword_init: true)

    module_function

    # The document in a file: JSON, or YAML (a .yaml or .yml extension). Aliases are allowed in YAML, nothing else is
    # constructed, so the file can only give data.
    def load(path)
      raise CompileError, "openapi: #{path} does not exist" unless File.file?(path)

      text = File.read(path)
      doc =
        if path.match?(/\.ya?ml\z/i)
          YAML.safe_load(text, aliases: true)
        else
          JSON.parse(text)
        end
      raise CompileError, "openapi: #{path} must hold one object at the top (an OpenAPI document)" unless doc.is_a?(Hash)

      doc
    rescue JSON::ParserError => e
      raise CompileError, "openapi: #{path} is not valid JSON (#{e.message.lines.first.to_s.strip}); a file ending in .yaml or .yml is read as YAML"
    rescue Psych::Exception => e
      raise CompileError, "openapi: #{path} is not valid YAML (#{e.message})"
    end

    # The version line of the document: "3.0" or "3.1". Swagger 2 and anything newer are refused with a pointer.
    def version(doc, path)
      if doc["swagger"]
        raise CompileError, "openapi: #{path} is a Swagger #{doc['swagger']} document; only OpenAPI 3.0 and 3.1 are supported (convert it, for example with the Swagger Editor's \"Convert to OpenAPI 3\")"
      end
      v = doc["openapi"].to_s
      raise CompileError, "openapi: #{path} has no `openapi` version (expected \"3.0.x\" or \"3.1.x\")" if v.empty?

      minor = v[/\A3\.([01])(?:\.\d+)?\z/, 1] or
        raise CompileError, "openapi: #{path} says openapi #{v.inspect}; only 3.0.x and 3.1.x are supported"
      "3.#{minor}"
    end

    # The plans for every operation that passes the filters. `include_tags` keeps the operations with at least one of the
    # tags, `exclude` drops operations by operationId (or by "METHOD /path" when there is none).
    def plan(doc, path, include_tags: nil, exclude: nil)
      ver = version(doc, path)
      paths = doc["paths"]
      raise CompileError, "openapi: #{path} has no `paths`" unless paths.is_a?(Hash) && !paths.empty?

      plans = []
      paths.each do |template, item|
        next unless item.is_a?(Hash)

        item = deref(doc, item, path)
        shared = (item["parameters"] || []).map { |p| deref(doc, p, path) }
        METHODS.each do |method|
          op = item[method] or next
          plans << plan_operation(doc, path, ver, template, method, op, shared)
        end
      end
      raise CompileError, "openapi: #{path} has no operations (a path item needs get, post, put, delete, patch, head or options)" if plans.empty?

      filter(plans, path, include_tags, exclude)
    end

    def filter(plans, path, include_tags, exclude)
      if include_tags
        known = plans.flat_map(&:tags).uniq
        unknown = include_tags - known
        unless unknown.empty?
          raise CompileError, "openapi: `include_tags:` names #{unknown.map(&:inspect).join(', ')}, which no operation in #{path} has (tags: #{known.empty? ? 'none' : known.join(', ')})"
        end
        plans = plans.select { |pl| (pl.tags & include_tags).any? }
      end
      if exclude
        names = plans.flat_map { |pl| [pl.id, pl.name] }.compact
        unknown = exclude - names
        unless unknown.empty?
          raise CompileError, "openapi: `exclude:` names #{unknown.map(&:inspect).join(', ')}, which is not an operation of #{path} (operations: #{plans.map { |pl| pl.id || pl.name }.join(', ')})"
        end
        plans = plans.reject { |pl| exclude.include?(pl.id) || exclude.include?(pl.name) }
      end
      raise CompileError, "openapi: the filters leave no operation of #{path}" if plans.empty?

      names = plans.group_by(&:name).select { |_, list| list.size > 1 }
      unless names.empty?
        shown = names.map { |name, list| "`#{name}` is #{list.map { |pl| "#{pl.method.upcase} #{pl.path}" }.join(' and ')}" }.join("; ")
        raise CompileError, "openapi: two operations would be the tool of the same name: #{shown}; give them different operationIds or exclude one"
      end
      plans
    end

    def plan_operation(doc, path, ver, template, method, op, shared)
      id = op["operationId"].is_a?(String) && !op["operationId"].strip.empty? ? op["operationId"] : nil
      where = "#{method.upcase} #{template}"
      name = tool_name(id || "#{method}_#{template}")
      params = merge_parameters(shared, (op["parameters"] || []).map { |p| deref(doc, p, path) }, where)
      fields = []
      used = {}
      request = { "method" => method.upcase, "path" => template, "path_params" => [], "query" => [], "headers" => [], "body" => nil }
      schema = { "type" => "object", "properties" => {}, "required" => [] }
      defs = {}
      params.each do |p|
        parameter_field(doc, path, ver, where, p, fields, used, request, schema, defs)
      end
      missing = template.scan(/\{([^}]+)\}/).flatten - request["path_params"].map(&:first)
      raise CompileError, "openapi: #{where} has {#{missing.first}} in its path but no path parameter of that name" unless missing.empty?

      body_field(doc, path, ver, where, op["requestBody"], fields, used, request, schema, defs)
      schema["$defs"] = defs unless defs.empty?
      schema.delete("required") if schema["required"].empty?
      Plan.new(name: name, id: id, description: describe(op, where), method: method, path: template,
               annotations: annotations(method), fields: fields, schema: schema, request: request,
               tags: Array(op["tags"]).map(&:to_s), security: op.key?("security") ? op["security"] : doc["security"])
    end

    def merge_parameters(shared, own, where)
      list = {}
      (shared + own).each do |p|
        raise CompileError, "openapi: #{where} has a parameter that is not an object" unless p.is_a?(Hash)

        key = [p["in"], p["name"]]
        list[key] = p # an operation's own parameter replaces a path item's of the same name and place
      end
      list.values
    end

    # One parameter becomes one field of the tool's arguments.
    def parameter_field(doc, path, ver, where, param, fields, used, request, schema, defs)
      where_in = param["in"]
      unless PARAM_IN.include?(where_in)
        raise CompileError, "openapi: #{where} has the #{where_in} parameter `#{param['name']}`; only path, query and header parameters are supported (exclude the operation, or drop the parameter from the document)" if where_in == "cookie"

        raise CompileError, "openapi: #{where} has a parameter `#{param['name']}` in #{where_in.inspect}; expected path, query or header"
      end
      name = param["name"].to_s
      raise CompileError, "openapi: #{where} has a #{where_in} parameter without a name" if name.empty?

      required = where_in == "path" || param["required"] == true
      raw = param["schema"] || { "type" => "string" } # a $ref stays a $ref in the published schema, and is followed for the field
      sch = deref(doc, raw, path)
      field = field_for(doc, path, where, "#{where_in} parameter `#{name}`", sch, ver)
      field_name = unique_field_name(Naming.field(name), where_in, used)
      field["name"] = field_name
      field["description"] = param["description"] if param["description"].is_a?(String) && !param["description"].strip.empty?
      field["optional"] = true unless required
      fields << field
      published, = bundle(doc, path, ver, convert_schema(raw, ver), defs)
      published = published.merge("description" => field["description"]) if field["description"] && !published.key?("description")
      schema["properties"][field_name] = published
      schema["required"] << field_name if required
      explode = param.key?("explode") ? param["explode"] : (param["style"].nil? || param["style"] == "form")
      case where_in
      when "path" then request["path_params"] << [name, field_name]
      when "query" then request["query"] << { "name" => name, "field" => field_name, "list" => field["type"].end_with?("_list"), "explode" => explode ? true : false }
      when "header" then request["headers"] << { "name" => name, "field" => field_name, "list" => field["type"].end_with?("_list") }
      end
      check_style(where, where_in, name, param)
    end

    DEFAULT_STYLE = { "path" => "simple", "query" => "form", "header" => "simple" }.freeze

    # Only each place's default style is supported (a path and a header value as `simple`, a query as `form`).
    def check_style(where, where_in, name, param)
      style = param["style"]
      return if style.nil? || style == DEFAULT_STYLE[where_in]

      raise CompileError, "openapi: #{where} has #{where_in} parameter `#{name}` with style #{style.inspect}; only the default style (#{DEFAULT_STYLE[where_in]}) is supported (exclude the operation)"
    end

    # The request body: JSON only, as one field called `body` whose schema is the body's schema.
    def body_field(doc, path, ver, where, body, fields, used, request, schema, defs)
      return if body.nil?

      body = deref(doc, body, path)
      content = body["content"] || {}
      type = content.keys.find { |t| t.match?(JSON_TYPE) }
      if type.nil?
        raise CompileError, "openapi: #{where} takes a request body of #{content.keys.empty? ? 'no declared type' : content.keys.join(', ')}; only application/json bodies are supported (exclude the operation)"
      end
      raw = content[type]["schema"] || {}
      name = unique_field_name("body", "body", used)
      field = { "name" => name, "type" => OpaqueName }
      field["description"] = body["description"] if body["description"].is_a?(String) && !body["description"].strip.empty?
      field["optional"] = true unless body["required"] == true
      fields << field
      published, = bundle(doc, path, ver, convert_schema(raw, ver), defs)
      published = published.merge("description" => field["description"]) if field["description"] && !published.key?("description")
      schema["properties"][name] = published
      schema["required"] << name if body["required"] == true
      request["body"] = name
    end

    # The type a field takes from a schema. Strings, integers, numbers, booleans and arrays of strings or integers map to
    # fields with their constraints; anything else (objects, unions, arrays of those) is only accepted as a body.
    def field_for(_doc, _path, where, what, sch, ver)
      sch = convert_schema(sch, ver)
      type = sch["type"]
      type = (Array(type) - ["null"]).first if type.is_a?(Array)
      field =
        case type
        when "string" then string_field(sch)
        when "integer" then numeric_field(sch, sch["format"] == "int32" ? "i32" : "i64")
        when "number" then numeric_field(sch, "f64")
        when "boolean" then { "type" => "bool" }
        when "array" then array_field(where, what, sch)
        else
          raise CompileError, "openapi: #{where}: the #{what} has a #{type ? "schema of type #{type.inspect}" : 'schema without a type'}; a parameter must be a string, integer, number, boolean or an array of strings or integers (exclude the operation)"
        end
      field
    end

    FORMATS = { "date-time" => "date_time", "date" => "date", "uuid" => "uuid", "email" => "email", "uri" => "uri",
                "hostname" => "hostname", "ipv4" => "ipv4", "ipv6" => "ipv6" }.freeze

    def string_field(sch)
      field = { "type" => "string" }
      field["enum"] = sch["enum"] if sch["enum"].is_a?(Array) && sch["enum"].all?(String) && !sch["enum"].empty?
      field["min_length"] = sch["minLength"] if sch["minLength"].is_a?(Integer) && sch["minLength"] >= 0
      field["max_length"] = sch["maxLength"] if sch["maxLength"].is_a?(Integer) && sch["maxLength"] >= 0
      field["format"] = FORMATS[sch["format"]] if FORMATS.key?(sch["format"])
      field
    end

    # The numeric bounds a field can enforce. A schema may give an inclusive and an exclusive bound at once; the field
    # takes the stricter of the two, because the server enforces it. `min:`/`max:` and their exclusive forms cannot be
    # combined in one field. `multipleOf` is enforced for integer fields only: an exact multiple of a binary float is
    # not well defined, so a number's `multipleOf` stays advice in the published schema.
    def numeric_field(sch, type)
      field = { "type" => type }
      int = type != "f64"
      min = sch["minimum"] if sch["minimum"].is_a?(Numeric) && (!int || sch["minimum"].is_a?(Integer))
      exclusive_min = sch["exclusiveMinimum"] if sch["exclusiveMinimum"].is_a?(Numeric) && (!int || sch["exclusiveMinimum"].is_a?(Integer))
      if exclusive_min && (min.nil? || exclusive_min >= min)
        field["exclusive_min"] = exclusive_min
      elsif min
        field["min"] = min
      end
      max = sch["maximum"] if sch["maximum"].is_a?(Numeric) && (!int || sch["maximum"].is_a?(Integer))
      exclusive_max = sch["exclusiveMaximum"] if sch["exclusiveMaximum"].is_a?(Numeric) && (!int || sch["exclusiveMaximum"].is_a?(Integer))
      if exclusive_max && (max.nil? || exclusive_max <= max)
        field["exclusive_max"] = exclusive_max
      elsif max
        field["max"] = max
      end
      field["multiple_of"] = sch["multipleOf"] if int && sch["multipleOf"].is_a?(Integer) && sch["multipleOf"].positive?
      field
    end

    def array_field(where, what, sch)
      items = sch["items"].is_a?(Hash) ? sch["items"] : {}
      type = { "string" => "string_list", "integer" => "i64_list" }[items["type"]]
      raise CompileError, "openapi: #{where}: the #{what} is an array of #{items['type'] || 'something untyped'}; only arrays of strings or integers are supported (exclude the operation)" unless type

      field = { "type" => type }
      field["min_items"] = sch["minItems"] if sch["minItems"].is_a?(Integer) && sch["minItems"] >= 0
      field["max_items"] = sch["maxItems"] if sch["maxItems"].is_a?(Integer) && sch["maxItems"] >= 0
      field
    end

    OpaqueName = "OpenApi::Value"

    def unique_field_name(base, where_in, used)
      name = base
      name = "#{base}_#{where_in}" if used.key?(name)
      raise CompileError, "openapi: two arguments of one operation would both be called `#{name}`; rename one in the document" if used.key?(name)

      used[name] = true
      name
    end

    def describe(op, where)
      text = [op["summary"], op["description"]].select { |s| s.is_a?(String) && !s.strip.empty? }.map(&:strip).uniq.join("\n\n")
      text.empty? ? where : text
    end

    # What HTTP says about a method (RFC 9110): get, head and options are safe; those and put and delete are idempotent.
    def annotations(method)
      ann = { "open_world" => true }
      ann["read_only"] = true if SAFE.include?(method)
      ann["idempotent"] = true if IDEMPOTENT.include?(method) && !SAFE.include?(method)
      ann
    end

    # $ref to a place inside the document (#/components/...), followed until it is not a $ref.
    def deref(doc, node, path, seen = [])
      return node unless node.is_a?(Hash) && node["$ref"].is_a?(String)

      ref = node["$ref"]
      raise CompileError, "openapi: #{path} refers to #{ref}, which is outside the document; only references that start with #/ are supported" unless ref.start_with?("#/")
      raise CompileError, "openapi: #{ref} refers to itself" if seen.include?(ref)

      target = ref.delete_prefix("#/").split("/").map { |s| s.gsub("~1", "/").gsub("~0", "~") }.reduce(doc) do |acc, key|
        acc.is_a?(Hash) ? acc[key] : (acc.is_a?(Array) ? acc[key.to_i] : nil)
      end
      raise CompileError, "openapi: #{ref} in #{path} points at nothing" if target.nil?

      deref(doc, target, path, seen + [ref])
    end

    # OpenAPI 3.0 writes some things 3.1 (JSON Schema 2020-12) writes differently; the tool publishes 2020-12.
    def convert_schema(sch, ver)
      return sch unless sch.is_a?(Hash)

      out = sch.reject { |k, _| %w[xml externalDocs discriminator].include?(k) }
      if ver == "3.0"
        if out.delete("nullable") == true && out["type"].is_a?(String)
          out["type"] = [out["type"], "null"]
          out["enum"] = out["enum"] + [nil] if out["enum"].is_a?(Array) && !out["enum"].include?(nil)
        end
        %w[minimum maximum].each do |bound|
          flag = "exclusive#{bound.capitalize}"
          next unless out[flag].is_a?(TrueClass) || out[flag].is_a?(FalseClass)

          out[flag] = out.delete(bound) if out.delete(flag) == true && out.key?(bound)
        end
        out["examples"] = [out.delete("example")] if out.key?("example")
      end
      %w[properties patternProperties $defs].each do |k|
        out[k] = out[k].transform_values { |v| convert_schema(v, ver) } if out[k].is_a?(Hash)
      end
      %w[items additionalProperties not if then else contains propertyNames].each do |k|
        out[k] = convert_schema(out[k], ver) if out[k].is_a?(Hash)
      end
      %w[allOf anyOf oneOf prefixItems].each do |k|
        out[k] = out[k].map { |v| convert_schema(v, ver) } if out[k].is_a?(Array)
      end
      out
    end

    # Rewrites every $ref to a component schema as #/$defs/Name and copies the schemas it needs into defs, so a tool's
    # schema stands alone.
    def bundle(doc, path, ver, sch, defs)
      walk = lambda do |node|
        case node
        when Hash
          if node["$ref"].is_a?(String)
            ref = node["$ref"]
            m = ref.match(%r{\A#/components/schemas/([^/]+)\z}) or
              raise CompileError, "openapi: #{path} refers to #{ref}; inside a schema only #/components/schemas/Name references are supported"
            name = m[1]
            unless defs.key?(name)
              defs[name] = nil # reserve the name first, so a schema that refers to itself ends
              src = doc.dig("components", "schemas", name) or raise CompileError, "openapi: #{ref} in #{path} points at nothing"
              defs[name] = walk.call(convert_schema(src, ver))
            end
            node.reject { |k, _| k == "$ref" }.merge("$ref" => "#/$defs/#{name}")
          else
            node.transform_values { |v| walk.call(v) }
          end
        when Array then node.map { |v| walk.call(v) }
        else node
        end
      end
      [walk.call(sch), defs]
    end

    # Names in the document become names in the DSL: letters, digits and underscores, snake_case, never a keyword.
    module Naming
      module_function

      def snake(text)
        s = text.to_s.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z0-9])([A-Z])/, '\1_\2')
        s = s.gsub(/[^A-Za-z0-9]+/, "_").downcase.gsub(/\A_+|_+\z/, "")
        s = "op_#{s}" if s.empty? || s.match?(/\A\d/)
        s
      end

      def field(text)
        s = snake(text)
        RUST_KW.include?(s) ? "#{s}_" : s
      end
    end

    def tool_name(text) = Naming.field(text)

    # The Rust helpers every OpenAPI tool shares: percent-encoding for a path segment, and the request itself. A response
    # that is a success (2xx) is the tool's result; any other status is the same text as an error result, because a
    # failed API call is something the model can read and react to (MCP: a tool execution error). Both texts are
    # {"status": 404, "body": ...} with the body as JSON when it parses and as a string when it does not. A request that
    # never got an answer says so, with the address and the reason, and logs the same line to the server's stderr; no
    # header or body is ever logged.
    HELPERS = <<~'RS'
      fn openapi_pct(value: &str) -> String {
          let mut out = String::new();
          for b in value.bytes() {
              if b.is_ascii_alphanumeric() || b"-._~".contains(&b) {
                  out.push(b as char);
              } else {
                  out.push_str(&format!("%{:02X}", b));
              }
          }
          out
      }

      fn openapi_request(
          method: &str,
          url: &str,
          query: &[(String, String)],
          headers: &[(String, String)],
          body: Option<&str>,
          auth_header: &str,
          auth_scheme: &str,
          auth_value: &str,
      ) -> Result<String, String> {
          let agent = ureq::AgentBuilder::new().timeout(std::time::Duration::from_secs(30)).build();
          let mut request = agent.request(method, url);
          for (key, value) in query {
              request = request.query(key, value);
          }
          for (key, value) in headers {
              request = request.set(key, value);
          }
          if !auth_header.is_empty() {
              let value = if auth_scheme.is_empty() { auth_value.to_string() } else { format!("{auth_scheme} {auth_value}") };
              request = request.set(auth_header, &value);
          }
          let outcome = match body {
              Some(text) => request.set("Content-Type", "application/json").send_string(text),
              None => request.call(),
          };
          let (status, ok, text) = match outcome {
              Ok(response) => {
                  let status = response.status();
                  (status, true, response.into_string().unwrap_or_default())
              }
              Err(ureq::Error::Status(status, response)) => (status, false, response.into_string().unwrap_or_default()),
              Err(error) => {
                  let line = format!("the request {method} {url} got no answer: {error}");
                  eprintln!("{line}");
                  return Err(line);
              }
          };
          let body: serde_json::Value = serde_json::from_str(&text).unwrap_or(serde_json::Value::String(text));
          let answer = serde_json::json!({ "status": status, "body": body }).to_string();
          if ok { Ok(answer) } else { Err(answer) }
      }
    RS

    # The body of a tool as the emitter wants it (locals, a final expression, fallible), written in Rust. `base` is
    # { "setting" => name } or { "url" => text }; `auth` is nil or { "header", "scheme", "setting" }.
    def body_ir(plan, base:, auth:)
      req = plan.request
      fields = plan.fields.to_h { |f| [f["name"], f] }
      locals = []
      locals << path_local(req["path"], req["path_params"])
      locals << pairs_local("__query", req["query"], fields, explode: true)
      locals << pairs_local("__headers", req["headers"], fields, explode: false)
      locals << body_local(req["body"], fields)
      base_expr = base["setting"] ? "settings().#{base['setting']}.trim_end_matches('/')" : rust_str(base["url"].sub(%r{/+\z}, ""))
      auth_args = auth ? [rust_str(auth["header"]), rust_str(auth["scheme"].to_s), "&settings().#{auth['setting']}"] : ['""', '""', '""']
      locals << "let __url = format!(\"{}{}\", #{base_expr}, __path);"
      locals << "let __answer = openapi_request(#{rust_str(req['method'])}, &__url, &__query, &__headers, __body.as_deref(), #{auth_args.join(', ')})?;"
      { "args" => plan.fields.map { |f| f["name"] }, "locals" => locals, "expr" => "__answer", "type" => "string", "fallible" => true }
    end

    def rust_str(text) = text.to_s.inspect

    # The path with every {name} filled from its field, percent-encoded.
    def path_local(template, path_params)
      fields = path_params.to_h
      args = []
      fmt = template.split(/(\{[^}]+\})/).map do |part|
        if (m = part.match(/\A\{([^}]+)\}\z/))
          args << "openapi_pct(&#{fields.fetch(m[1])}.to_string())"
          "{}"
        else
          part.gsub("{", "{{").gsub("}", "}}")
        end
      end.join
      "let __path = format!(#{rust_str(fmt)}#{args.map { |a| ", #{a}" }.join});"
    end

    # Query pairs or header pairs: an optional field is only sent when it is there, a list is repeated (query, `explode`)
    # or joined with commas.
    def pairs_local(var, entries, fields, explode:)
      return "let #{var}: Vec<(String, String)> = Vec::new();" if entries.empty?

      lines = ["let mut #{var}: Vec<(String, String)> = Vec::new();"]
      entries.each do |e|
        field = fields.fetch(e["field"])
        optional = field["optional"]
        name = rust_str(e["name"])
        value = optional ? "value" : e["field"]
        send =
          if e["list"] && explode && e["explode"]
            "for item in #{optional ? 'value.iter()' : "#{value}.iter()"} { #{var}.push((#{name}.to_string(), item.to_string())); }"
          elsif e["list"]
            "#{var}.push((#{name}.to_string(), #{value}.iter().map(|item| item.to_string()).collect::<Vec<_>>().join(\",\")));"
          else
            "#{var}.push((#{name}.to_string(), #{value}.to_string()));"
          end
        lines << (optional ? "if let Some(value) = &#{e['field']} { #{send} }" : send.sub(/\A/, ""))
      end
      lines.join("\n")
    end

    def body_local(name, fields)
      return "let __body: Option<String> = None;" unless name

      encode = ->(v) { "serde_json::to_string(#{v}).map_err(|e| format!(\"the body cannot be encoded: {e}\"))?" }
      if fields.fetch(name)["optional"]
        "let __body: Option<String> = match &#{name} { Some(value) => Some(#{encode.call('value')}), None => None };"
      else
        "let __body: Option<String> = Some(#{encode.call("&#{name}")});"
      end
    end
  end
end

