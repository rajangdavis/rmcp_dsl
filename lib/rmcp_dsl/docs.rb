# frozen_string_literal: true

module RmcpDsl
  # One line of documentation for every DSL call and keyword, and the fixed choices of keywords whose values come
  # from a set the signature table's kinds cannot express (a list of strings such as `audience:`). The generated
  # skill, completion and hover all read this, so a sentence is written once. test/test_dsl_completeness.rb fails
  # when SIG gains a call or keyword with no entry here.
  module Docs
    # call name => what the call declares
    CALLS = {
      server: "The one top-level call: names the server and holds everything it offers; needs a version and a transport.",
      params: "A struct of arguments (fields) for a tool, a prompt or a resource template; every params must be used.",
      output: "A structured result a tool may return; its fields are typed and the client gets JSON and an output schema.",
      field: "One field of a params or output struct, with a snake_case name and a type symbol such as :string or :i32.",
      tool: "A tool: a function the model can call. Its body returns the result text (or a `result(...)` for an output).",
      helper: "A typed function that tool bodies and later helpers can call by name; it must be called somewhere.",
      prompt: "A prompt: a template that returns one user message, as text or content blocks, or a conversation of `message` blocks.",
      resource: "A resource: text a client can read at a URI; a URI with {placeholders} makes it a template.",
      body: "The Ruby-subset code that computes the result of a tool, a prompt message or a resource.",
      message: "One message of a prompt conversation, sent as the user or the assistant; use it instead of one `body`.",
      complete: "A block that answers completions for a prompt's or resource template's arguments; it gets the argument name and the text typed so far.",
      transport: "How the server talks to a client: standard input and output (:stdio) or streamable HTTP (:http).",
      rust_crate: "Adds a Cargo dependency (a crate name and a version) to the generated server for injected Rust.",
      rust_item: "Injects Rust source text into the generated crate unchecked; the compiler prints a notice for it.",
      rust_fn: "Declares the argument and result types of a Rust function so bodies can call it as `rust(:name, ...)`.",
      use_bindings: "Loads bindings/NAME.rb, found next to the DSL file, so bodies can call its typed functions as Module.method.",
      setting: "A value the server reads from an environment variable when it starts, such as an API address or key; bodies read it with setting(:name).",
      openapi: "Makes one tool per operation of an OpenAPI 3.0 or 3.1 file beside this one, calling the API it describes; checked when compiled.",
      rust_file: "Copies a hand-written .rs file from beside the DSL file into the crate as a module that rust_fn can point at.",
      cmd_fn: "A function that runs a subprocess with fixed arguments and returns its output as a string; no shell is used.",
      script_fn: "A function that runs inline code in an interpreter such as python3 or ruby and returns its output as a string.",
      feature: "Declares a backend feature the server uses, such as `:logging`; a gated body built-in needs it and it advertises the capability."
    }.freeze

    # [call name, keyword name] => what the keyword means
    KEYWORDS = {
      %i[tool meta] => "Static metadata clients may read, a JSON object literal sent as `_meta`; keys follow the MCP rules (reverse-DNS prefix such as com.example/).",
      %i[prompt meta] => "Static metadata clients may read, a JSON object literal sent as `_meta`; keys follow the MCP rules (reverse-DNS prefix such as com.example/).",
      %i[resource meta] => "Static metadata clients may read, a JSON object literal sent as `_meta`; keys follow the MCP rules (reverse-DNS prefix such as com.example/).",
      %i[server version] => "The server's version as semver such as 0.1.0, reported to clients.",
      %i[server instructions] => "Text that tells a model how to use this server as a whole.",
      %i[server title] => "A human-readable name that clients may show instead of the server name.",
      %i[server description] => "A short description of what the server does.",
      %i[server website_url] => "An http or https address of a page about the server.",
      %i[server icon] => "An icon for the server: an http or https address, or a data: URI.",

      %i[field description] => "What the field means; it is part of the schema the model reads, so say what a valid value is.",
      %i[field optional] => "When true the caller may leave the field out and the body sees nil; it cannot be combined with `default:`.",
      %i[field default] => "The value used when the caller omits the field, so the body always has one; it must pass the field's other limits.",
      %i[field min] => "The smallest allowed number; only for :i32, :i64 and :f64 fields, and an integer for the integer types.",
      %i[field max] => "The largest allowed number; only for :i32, :i64 and :f64 fields, and not below `min:`.",
      %i[field exclusive_min] => "The smallest allowed number, which the value must be above; only for :i32, :i64 and :f64 fields, and an integer for the integer types.",
      %i[field exclusive_max] => "The largest allowed number, which the value must be below; only for :i32, :i64 and :f64 fields, and an integer for the integer types.",
      %i[field multiple_of] => "The value must be a multiple of this positive integer; only for :i32 and :i64 fields.",
      %i[field min_length] => "The fewest characters a :string field may have; the generated server enforces it.",
      %i[field max_length] => "The most characters a :string field may have; not below `min_length:`.",
      %i[field pattern] => "A Rust regex that a :string value must match; the generated server enforces it.",
      %i[field enum] => "The only strings a :string field accepts: a non-empty list of distinct values, also offered as prompt completions.",
      %i[field complete] => "Names a helper that offers completion values for this :string prompt or template argument, instead of `enum:`.",
      %i[field format] => "A JSON schema format hint for a :string field, such as :email or :uri; it is advice to the client, not checked.",
      %i[field min_items] => "The fewest items a list field (:string_list, :i64_list or :f64_list, or list(:Name)) may have.",
      %i[field max_items] => "The most items a list field (:string_list, :i64_list or :f64_list, or list(:Name)) may have; not below `min_items:`.",

      %i[tool params] => "The params struct, declared above, that gives the tool its arguments.",
      %i[tool description] => "What the tool does; the model reads it to decide when to call the tool.",
      %i[tool title] => "A human-readable name that clients may show instead of the tool name.",
      %i[tool read_only] => "Tells a client the tool does not change anything, so it is safe to call without asking.",
      %i[tool destructive] => "Tells a client the tool may delete or overwrite things, so it may ask first; only meaningful when `read_only:` is false.",
      %i[tool idempotent] => "Tells a client that calling the tool again with the same arguments has no further effect; only meaningful when `read_only:` is false.",
      %i[tool open_world] => "Tells a client the tool reaches outside systems such as the web, so its results can vary and are untrusted.",
      %i[tool output] => "The output struct, declared above, that the tool returns; the body then ends in `result(:Name, ...)`.",
      %i[server page_size] => "How many tools, prompts, resources or templates one page of a list holds; clients follow nextCursor for the rest.",
      %i[setting env] => "The environment variable the value is read from; the server refuses to start when a required one is missing or empty.",
      %i[setting description] => "What the value is for, shown in the message when the server cannot start without it.",
      %i[setting default] => "The value used when the environment variable is not set, which makes the setting not required.",
      %i[setting optional] => "True when the server can run without the value; the body then gets a string or nil.",
      %i[setting secret] => "True for a key or token: a body can only pass it to a binding or rust_fn function, never print or return it.",
      %i[tool input_schema] => "A JSON Schema object literal that replaces the schema made from the fields; its properties and required list are checked against them.",
      %i[openapi base_url] => "The setting that holds the API's address; without it the first server address of the document is used.",
      %i[openapi auth_setting] => "The setting whose value is sent with every request, as a bearer token unless auth_header: or auth_scheme: says otherwise.",
      %i[openapi auth_header] => "The header that carries the auth_setting value (default Authorization).",
      %i[openapi auth_scheme] => "A word before the value in the auth header, such as Bearer (default Bearer for Authorization, none for other headers).",
      %i[openapi include_tags] => "Only the operations that have at least one of these tags become tools.",
      %i[openapi exclude] => "Operations to leave out, by operationId (or by the tool name made from the method and path).",
      %i[tool icon] => "An icon for the tool: an http or https address, or a data: URI.",
      %i[resource size] => "The size of the content in bytes, shown to clients; checked against the body when that is a plain string.",
      %i[tool updates] => "Resource uris this tool changes, so subscribed clients are told once it succeeds; {field} fills from the params.",
      %i[tool resource_list_changed] => "True when the tool adds or removes resources; clients that asked are told the resource list changed.",
      %i[tool task] => "Lets a client that declared the tasks extension poll for the result as a task; every other client still gets it directly.",
      %i[tool task_ttl_ms] => "How long, in milliseconds, a finished task stays available (the extension's ttlMs; default 300000). Needs task: true.",
      %i[tool task_poll_ms] => "The polling interval clients are asked to use, in milliseconds (pollIntervalMs; default 1000). Needs task: true.",

      %i[helper args] => "The argument types in order, such as [:string, :i64]; write them out, and use a trailing ? such as :string? for a nil-able parameter.",
      %i[helper kw] => "Keyword parameters a helper takes: a hash of `name: [type, required]`, declared after the positional ones and passed by name at the call site.",
      %i[helper returns] => "The result type; a trailing ? as in :string? means the helper may return nil.",
      %i[helper async] => "Not supported: async is inferred from the body, so `async: true` on helper is refused.",

      %i[prompt params] => "The params struct, declared above, that gives the prompt its arguments; every field must be :string.",
      %i[prompt description] => "What the prompt is for; a client shows it when listing prompts.",
      %i[prompt title] => "A human-readable name that clients may show instead of the prompt name.",
      %i[prompt icon] => "An icon for the prompt: an http or https address, or a data: URI.",

      %i[resource uri] => "The address clients read, written scheme://path; {name} placeholders make a template and need `params:`.",
      %i[resource description] => "What the resource contains; a client shows it when listing resources.",
      %i[resource mime_type] => "The media type of the text, such as text/markdown or text/plain.",
      %i[resource title] => "A human-readable name that clients may show instead of the resource name.",
      %i[resource icon] => "An icon for the resource: an http or https address, or a data: URI.",
      %i[resource audience] => "Who the resource is for: a non-empty list of distinct values from \"user\" and \"assistant\".",
      %i[resource priority] => "How important the resource is, from 0 (least) to 1 (most), as an integer or a float.",
      %i[resource params] => "The params struct with one :string field per {placeholder} in `uri:`; only for a template.",

      %i[transport port] => "The TCP port, 0 to 65535, that `transport :http` listens on at 127.0.0.1; required for :http, refused for :stdio.",
      %i[transport oauth_issuer] => "The setting holding the OAuth issuer URL; every request to /mcp must carry a JWT that issuer signed (RS256 or ES256); only for :http.",
      %i[transport oauth_audience] => "The setting holding the audience (`aud`) a token must have been issued for; required with `oauth_issuer:`.",
      %i[transport oauth_resource] => "The setting holding this server's public base URL for the protected-resource metadata; without it, http://127.0.0.1 and the port.",
      %i[transport auth_setting] => "The secret setting every request to /mcp must carry as `Authorization: Bearer ...`, or get a 401; only for :http.",

      %i[rust_fn args] => "The argument types in order, such as [:string, :i32].",
      %i[rust_fn returns] => "The result type of the Rust function.",
      %i[rust_fn from] => "The `as:` name of the rust_file module that holds the function; leave it out for a function from rust_item.",
      %i[rust_fn async] => "True when the Rust function is async; a body that calls it awaits the eventual value.",

      %i[rust_file as] => "The module name the file gets in the crate, and the name `from:` refers to; it cannot be main or tests.",
      %i[rust_file uses] => "Set to :subprocess when the module starts subprocesses, so the generated crate includes the subprocess helper.",

      %i[cmd_fn program] => "The program to run, such as tr; only letters, digits and . _ + - / are allowed, and no shell is involved.",
      %i[cmd_fn argv] => "Fixed command line arguments placed before the call's own arguments, one list entry per argument.",
      %i[cmd_fn args] => "The types of the arguments the body passes, such as [:string]; they become extra arguments or stdin.",
      %i[cmd_fn returns] => "The result type; always :string, the program's standard output.",
      %i[cmd_fn pass] => "How arguments reach the program: :argv adds them to the command line (the default), :stdin writes one string to standard input.",
      %i[cmd_fn async] => "Not supported: a subprocess is blocking, so `async: true` on cmd_fn is refused.",

      %i[script_fn interpreter] => "The interpreter to run, such as python3, ruby, node, sh or bash.",
      %i[script_fn code] => "The source text that the interpreter runs; it receives the call's arguments as command line arguments.",
      %i[script_fn args] => "The types of the arguments the body passes, such as [:string].",
      %i[script_fn returns] => "The result type; always :string, the script's standard output.",
      %i[script_fn flag] => "The interpreter option that takes the code (such as -c); needed only for an interpreter the compiler does not know.",
      %i[script_fn async] => "Not supported: a subprocess is blocking, so `async: true` on script_fn is refused."
    }.freeze

    # [call name, keyword name] => the values the keyword accepts, when SIG's kind does not already list them
    CHOICES = {
      %i[resource audience] => %w[user assistant]
    }.freeze

    module_function

    def call(name) = CALLS[name.to_sym]

    def keyword(call, keyword) = KEYWORDS[[call.to_sym, keyword.to_sym]]

    def choices(call, keyword) = CHOICES[[call.to_sym, keyword.to_sym]]
  end
end
