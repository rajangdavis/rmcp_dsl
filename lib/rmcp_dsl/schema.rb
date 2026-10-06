# frozen_string_literal: true

require_relative "features"

module RmcpDsl
  # DSL type -> Rust type.
  TYPES = { i32: "i32", i64: "i64", f64: "f64", bool: "bool", string: "String" }.freeze

  # Field types beyond the scalars: lists of strings, integers or floats. A field may also name another
  # params struct (a CamelCase symbol) to nest an object.
  FIELD_LISTS = %i[string_list i64_list f64_list].freeze
  # JSON schema string formats a field can advertise (:date_time is "date-time"). They are advice to the
  # client, as the JSON Schema standard treats `format`, not something the server checks.
  FORMATS = %i[uri email date_time date uuid hostname ipv4 ipv6].freeze

  # Types a helper declares for its arguments and result. Lists are spelled out, and a trailing ? means
  # nil-able: string? is "a string or nil".
  HELPER_TYPES = { string: :string, i32: :i32, i64: :i64, f64: :f64, bool: :bool,
                   string_list: :strs, i64_list: :i64s, f64_list: :f64s,
                   string?: :ostr, i32?: :oi32, i64?: :oi64, f64?: :of64, bool?: :obool,
                   string_list?: :ostrs, i64_list?: :oi64s, f64_list?: :of64s }.freeze

  SNAKE  = /\A[a-z][a-z0-9_]*\z/
  CAMEL  = /\A[A-Z][A-Za-z0-9]*\z/
  SEMVER = /\A\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?\z/
  RUST_KW = %w[
    as async await break const continue crate dyn else enum extern false fn for if impl in let
    loop match mod move mut pub ref return self Self static struct super trait true type unsafe
    use where while abstract become box do final macro override priv try typeof unsized virtual yield
  ].freeze

  # The signature table: the single source of truth for what a DSL call accepts.
  #   in:    name of the enclosing call (:top for the file level)
  #   names: positional argument names, in order (used by bin/gen_rbi)
  #   pos:   positional argument kinds, in order
  #   kw:    keyword => [kind, required]
  #   block: nil (no block), :decls (only DSL calls inside) or :body (Ruby subset)
  # Kinds: :lit (a string, number or true/false literal), :fieldtype (a field type symbol), :bool (true or false), :num (integer or float literal), :uint (non-negative integer literal),
  #        :str (plain string literal), :snake / :camel (symbol literal naming a
  #        snake_case / CamelCase non-keyword identifier), or an Array of allowed symbol literals.
  SIG = {
    server: {
      in: :top, names: [:name], pos: [:str],
      kw: { version: [:str, true], instructions: [:str, false], title: [:str, false], description: [:str, false],
            website_url: [:str, false], icon: [:str, false], page_size: [:uint, false] },
      block: :decls
    },
    params: { in: :server, names: [:name], pos: [:camel], kw: {}, block: :decls },
    output: { in: :server, names: [:name], pos: [:camel], kw: {}, block: :decls },
    field: {
      in: %i[params output], names: %i[name type], pos: %i[snake fieldtype],
      kw: { description: [:str, false], optional: [:bool, false], default: [:lit, false],
            min: [:num, false], max: [:num, false], exclusive_min: [:num, false], exclusive_max: [:num, false],
            multiple_of: [:num, false], min_length: [:uint, false], max_length: [:uint, false],
            pattern: [:str, false], enum: [:strs, false], format: [FORMATS, false],
            min_items: [:uint, false], max_items: [:uint, false], complete: [:snake, false] },
      block: nil
    },
    tool: {
      in: :server, names: [:name], pos: [:snake],
      kw: { params: [:camel, true], description: [:str, true], title: [:str, false],
            read_only: [:bool, false], destructive: [:bool, false], idempotent: [:bool, false], open_world: [:bool, false],
            output: [:camel, false], icon: [:str, false], meta: [:json, false], input_schema: [:schema, false],
            task: [:bool, false], task_ttl_ms: [:uint, false], task_poll_ms: [:uint, false],
            updates: [:strs, false], resource_list_changed: [:bool, false] },
      block: :decls
    },
    helper: {
      in: :server, names: [:name], pos: [:snake],
      kw: { args: [:htypes, true], returns: [HELPER_TYPES.keys, true], kw: [:helper_kw, false], async: [:bool, false] },
      block: :body
    },
    prompt: {
      in: :server, names: [:name], pos: [:snake],
      kw: { params: [:camel, true], description: [:str, true], title: [:str, false], icon: [:str, false], meta: [:json, false] },
      block: :decls
    },
    resource: {
      in: :server, names: [:name], pos: [:snake],
      kw: { uri: [:str, true], description: [:str, false], mime_type: [:str, false], title: [:str, false], icon: [:str, false],
            audience: [:strs, false], priority: [:num, false], params: [:camel, false], meta: [:json, false],
            size: [:uint, false] },
      block: :decls
    },
    body: { in: %i[tool prompt resource], names: [], pos: [], kw: {}, block: :body },
    message: { in: :prompt, names: [:role], pos: [%i[user assistant]], kw: {}, block: :body },
    complete: { in: %i[prompt resource], names: [], pos: [], kw: {}, block: :body },
    transport: { in: :server, names: [:kind], pos: [%i[stdio http]], kw: { port: [:uint, false], auth_setting: [:snake, false], oauth_issuer: [:snake, false], oauth_audience: [:snake, false], oauth_resource: [:snake, false] }, block: nil },
    # A server-level feature gate: `feature :logging` is required before a gated body built-in such as
    # `log(...)` may be used, advertises the capability, and scopes the generated `#[allow(deprecated)]`.
    feature: { in: :server, names: [:name], pos: [Features::NAMES], kw: {}, block: nil },
    # Tier 2 (SKETCH.md): injected Rust. rust_fn declares the signature of a function that
    # lives in a rust_item block, so bodies can call it as rust(:name, args) and be type-checked.
    rust_crate: { in: :server, names: [:crate, :version], pos: [:str, :str], kw: {}, block: nil },
    rust_item: { in: :server, names: [:code], pos: [:str], kw: {}, block: nil },
    rust_fn: { in: :server, names: [:name], pos: [:snake],
               kw: { args: [:types, true], returns: [TYPES.keys, true], from: [:snake, false], async: [:bool, false] }, block: nil },
    # rust_file loads a hand-written .rs file that lives next to the DSL file as module src/<as>.rs;
    # `from:` on rust_fn says the function is in that module.
    # Load a trusted binding (bindings/<name>.rb); bodies then call Module.method(...) as plain Ruby.
    use_bindings: { in: :server, names: [:name], pos: [:snake], kw: {}, block: nil },
    # A value the server reads from its environment when it starts: setting(:name) in a body.
    setting: {
      in: :server, names: [:name], pos: [:snake],
      kw: { env: [:str, true], description: [:str, false], default: [:str, false], optional: [:bool, false], secret: [:bool, false] },
      block: nil
    },
    # Tools made from an OpenAPI document, one per operation, read when the server is compiled.
    openapi: {
      in: :server, names: [:file], pos: [:str],
      kw: { base_url: [:snake, false], auth_setting: [:snake, false], auth_header: [:str, false], auth_scheme: [:str, false],
            include_tags: [:strs, false], exclude: [:strs, false] },
      block: nil
    },
    rust_file: { in: :server, names: [:path], pos: [:str], kw: { as: [:snake, true], uses: [[:subprocess], false] }, block: nil },
    # Subprocess escape hatches (any language). Arguments are separate argv entries or stdin,
    # never shell text. Called from bodies as rust(:name, ...) like any rust_fn.
    cmd_fn: { in: :server, names: [:name], pos: [:snake],
              kw: { program: [:str, true], argv: [:strs, false], args: [:types, true],
                    returns: [[:string], true], pass: [%i[argv stdin], false], async: [:bool, false] }, block: nil },
    script_fn: { in: :server, names: [:name], pos: [:snake],
                 kw: { interpreter: [:str, true], code: [:str, true], args: [:types, true],
                       returns: [[:string], true], flag: [:str, false], async: [:bool, false] }, block: nil }
  }.freeze
end
