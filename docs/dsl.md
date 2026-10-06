# The DSL

Declaring a server, and generating tools from an OpenAPI document.

_See also: [README](../README.md)._

## How to declare a server

```ruby
server "notekit", version: "0.1.0", instructions: "Search with `search`; delete with `delete_note`." do
  params :SearchParams do
    field :query, :string, description: "Words to look for", min_length: 1, max_length: 40
    field :limit, :i32, optional: true, min: 1, max: 50
    field :kind, :string, optional: true, enum: ["all", "recent", "pinned"]
    field :tag, :string, optional: true, pattern: "^[a-z][a-z0-9-]*$"
  end

  tool :search, params: :SearchParams, description: "Search the notes",
                title: "Search notes", read_only: true, open_world: false do
    body do |query, limit, kind, tag|
      "#{query}|#{limit || 10}|#{kind || "all"}|#{tag || "-"}"
    end
  end

  transport :stdio
end
```

- **Fields** take `description:`, `optional:`, `default:`, and JSON schema constraints: `min:`/`max:` and
  `exclusive_min:`/`exclusive_max:`/`multiple_of:` on numbers, `min_length:`/`max_length:`/`pattern:`/`enum:` on strings,
  `min_items:`/`max_items:` on lists.
  The generated server also enforces the constraints and answers a violation with an error result, because
  a schema is only advice to the client. An optional field is nil-able in the body (`limit || 10`); a
  field with a `default:` is always present, and the default is advertised in the schema.
- **Structured results.** `output :Stats do field :count, :i64 ... end` declares a typed result (fields take
  `description:` and `optional:`, and may nest another output); `tool :stats, output: :Stats` returns it, and
  the body ends in `result(:Stats, count: 3, ...)` with every field given once and typed. Clients receive
  `structuredContent` (plus the same JSON as text) and the tool list publishes an `outputSchema`. Errors
  (`raise`) stay `isError` results.
- **Typed maps** are objects with string keys and one value type: `field :counts, map(:i64)`, `map(:string)`,
  `map(:f64)`, `map(:bool)`, `map(list(:string))`, a map of a params object (`map(:Address)`) or a nested map
  (`map(map(:i64))`). The schema says `additionalProperties`, nested for a map of maps. In a body, `m["k"]`
  is nil-able (use `|| default`; on a map of objects read fields with `&.`, and `m["a"]["b"]` indexes a map of
  maps), and `fetch`, `key?`, `keys`, `values` (a list of objects or maps when the value is one), `size`,
  `empty?`, `merge` work; `map`, `select`, `reject` and `each` take a `|k, v|` block (the String key and the
  value), with `map` returning a list and `select`/`reject` a new map of the same value type and `each`
  running the block for side effects; a literal is `{ "a" => 1 }` (string keys, values of one type; `{a: 1}` is refused
  because a symbol is a different key in Ruby) and `items.tally` counts a list of strings. A map is a Rust
  `BTreeMap`, as serde_json's own objects are, so keys come back sorted, not in insertion order. Maps are
  read-only: nothing changes one in place. `list(:string)` is the same as `:string_list`, and a field can be a
  list of objects, `field :offices, list(:Address)` (nil-able when `optional: true`, read `offices[0]&.city` or,
  in a block, `o.city`). Anything more complicated than these basic JSON shapes belongs in a binding.
- **A binding's own types** carry anything more complicated than basic JSON. A binding declares one with
  `class Value < RmcpDsl::Opaque; type_rust "serde_json::Value", wire: true; end` (see `examples/bindings/json.rb`).
  The DSL holds a value of it (`doc = Json.parse(text) || raise("not JSON")`), passes it to that binding's functions
  and may return it; it cannot look inside. `field :doc, Json::Value` makes it a tool field or result field,
  which needs `wire: true` (the Rust type is serde Serialize and Deserialize and schemars JsonSchema); without it a
  value lives only in bodies. See `examples/jsonkit.rmcp.rb`.
- **Settings** are values the server reads from its environment when it starts:
  `setting :base_url, env: "API_URL", default: "https://api.example.com"`, `setting :token, env: "API_TOKEN", secret: true`
  (also `optional: true` and `description:`). A body reads one with `setting(:token)`. A required setting that is missing or
  empty stops the server at startup with a message that names the variable (never its value). A **secret** can only
  be passed to a binding or `rust_fn` function: the compiler refuses to put it in text, return it or compare it, so a body
  cannot leak it. `examples/bindings/http.rb` is an HTTP client binding (`Http.get`, `get_bearer`, `get_with_header`,
  `post_json_bearer`; the body of a 2xx answer, or nil) built for this: see `examples/apikit.rmcp.rb`.
- **`input_schema:`** on a tool replaces the JSON Schema made from the fields with one written out as a literal. The
  compiler checks it against the fields (a property of a matching type for each, none for anything else, and `required`
  lists exactly the fields the server needs), so it cannot promise an argument shape the server does not accept.
- **`meta:`** on a tool, prompt or resource is static metadata sent as `_meta`: a JSON object written as a
  literal (`meta: { "com.example/tier" => "free" }`). Keys follow the MCP rules (an optional reverse-DNS prefix such as
  `com.example/`; prefixes the spec reserves, and the keys `progressToken`, `traceparent`, `tracestate` and
  `baggage`, are refused at compile time).
- **Field types** are `:string :i32 :i64 :f64 :bool`, lists (`:string_list`, `:i64_list`, `:f64_list`, also
  written `list(:string)`, `list(:i64)`, `list(:f64)`), typed maps (`map(:i64)`, see above), and a nested
  object: name another `params` declared above (`field :address, :Address`) and read it in the body as
  `address.city`; an `optional: true` object is read nil-safely as `address&.city`, and an unguarded
  `address.city` on it is refused. `format:` (`:uri :email :date_time :date :uuid :hostname :ipv4 :ipv6`)
  is advice to the client and is not checked by the server.
- **Tool annotations** (`title:`, `read_only:`, `destructive:`, `idempotent:`, `open_world:`) tell a
  client whether a tool is safe to call without asking.
- **`instructions:`** on the server is the text a model reads about how to use it. `title:`, `description:`,
  `website_url:` (http or https) and `icon:` (an http, https or `data:` URI) describe the server to a client.
  Tools, prompts and resources take `icon:` too, and prompts and tools take `title:`.

- **Prompts** (`prompt :name, params: :P, description: "..." do body ... end`) are tool-shaped templates
  whose body returns the text of one user message. Prompt arguments are completed: a `:string` field may name a
  helper with `complete: :helper` (one `:string` argument, returning `:string_list`), an `enum:` field offers its
  values, and a `complete do |arg, typed| ... end` block answers for every argument at once. The server advertises
  the `completions` capability and answers `completion/complete` with the values that start with what was typed
  (at most 100, with `total` and `hasMore`); a prompt or argument that does not exist is `-32602`, as the MCP spec
  says, and an argument with nothing to offer gets an empty answer. For a conversation, use `message :assistant do ... end`
  and `message :user do |topic| ... end` blocks, in order, instead of `body`. MCP passes prompt arguments as strings, so a prompt's
  params may only have `:string` fields.
- **Resources** (`resource :guide, uri: "notekit://guide", mime_type: "text/markdown" do body ... end`) are
  readable content at a URI; the body takes no parameters and runs on every read. A plain string is one text
  content; `text(s)` and `blob(base64)` build resource contents (a `blob` is base64 text), each with an optional
  `uri:` (default the uri read) and `mime_type:` (default the resource's, or `text/plain` for `text`), and a body
  may return an array of them for several contents per read. `audience: ["user"]` and `priority: 0.5` (0 to 1)
  tell a client who a resource is for and how much it matters.
- **Resource templates** are resources whose `uri:` has `{placeholders}` (RFC 6570): `{name}` is one value,
  `{+path}` keeps slashes, `{a,b}` several values, `{tags*}` a list, and `{?q,limit}` optional query variables.
  `resource :note, uri: "notes://{id}", params: :NoteParams do body do |id| ... end end` — a template needs
  `params:`, with a `:string` field for every placeholder (a `string_list` for `{tags*}`, `optional: true` for a
  query variable), and the field's `pattern:`, `enum:`, `min_length:` or `min_items:` checks the value. They are
  listed by `resources/templates/list` (`uriTemplate`), not `resources/list`. A placeholder matches everything
  up to the next `/`, `?` or `#` (it may be empty, as RFC 6570 allows) and is percent-decoded. The compiler
  refuses the other operators (`#`) and prefix modifiers (`:3`), an empty placeholder, a list where a plain
  `{name}` is written or an explode on a non-list, `+` with several variables, a `*` that does not stand alone,
  `{?a*}` (write `{?a}`), more than one `{?...}` or one that does not end the uri or sits beside a literal `?`,
  a placeholder with no field (or a field with no placeholder), a template with no `params:`, and two resources
  that could match the same uri. At run time a bad escape or a violated constraint is `-32602`, a uri that
  matches nothing is not-found, and a `raise` in the body also means the resource does not exist (`-32002`, or
  `-32602` for clients on protocol 2026-07-28; rmcp chooses), with the uri in `data`. Template arguments are
  completed (`completion/complete` with `ref/resource`): an `enum:` field or a `complete:` helper offers values,
  and a `complete do |arg, typed| ... end` block can compute them.
- **Helpers and injected Rust.** `helper :name, args: [:string], returns: :string do |text| ... end` declares a
  function that tool bodies, prompts, resources and later helpers call by name; types are always written out and
  a helper may only call helpers declared above it. `rust_item <<~'RS' ... RS` injects Rust, `rust_fn :name,
  args: ..., returns: ...` declares its signature (a body calls it as `rust(:name, ...)`), `rust_file` brings in
  a `.rs` file as a module, and `cmd_fn`/`script_fn` run a subprocess. Add `async: true` to a `rust_fn` (or to a
  binding's `rust "..."` template) whose Rust function is `async fn`: the declared `returns:` is the eventual
  value, and any body that calls it is compiled `async fn` and awaits it. Async is inferred, so a caller never
  says `async: true`; a tool body, helper, prompt body or resource body may await, a `gsub`/`sub` block and a
  Ruby-compiled binding may not (the call is refused with the reason), and `async: true` on `cmd_fn`/`script_fn`
  is refused because a subprocess is blocking. It is refused on a `helper` too: a helper is async exactly when
  its body calls an async function, so the caller does not write it.

`examples/notekit.rmcp.rb` and `make e2e-notekit` cover most of this; `examples/formkit.rmcp.rb` covers lists, nested
objects, defaults and formats; `examples/guide.rmcp.rb` is a server with no tools, only a prompt and a resource.

## Tools from an OpenAPI document

`openapi "spec.json"` (or `.yaml`/`.yml`) reads an OpenAPI 3.0 or 3.1 document when the server is
compiled and makes one tool per operation. The path is relative to the DSL file and must stay
beside it:

```ruby
server "shopkit", version: "0.1.0" do
  setting :shop_url, env: "SHOPKIT_URL", description: "the shop API's address"
  setting :shop_key, env: "SHOPKIT_KEY", secret: true, description: "the shop API's key"

  openapi "shopkit.openapi.json", base_url: :shop_url, auth_setting: :shop_key,
          auth_header: "X-Api-Key", exclude: ["deleteItem"]

  transport :stdio
end
```

- The tool name is the operation's `operationId` in snake_case, or the method and path when there
  is none; two operations that would share a name are a compile error. `include_tags:` keeps the
  operations that have at least one of the tags and `exclude:` drops them by `operationId` (or by
  tool name); a filter that matches nothing is refused.
- Path, query and header parameters become typed fields with their constraints, and a JSON
  `requestBody` becomes one `body` field. The tool's `inputSchema` is the document's schema with
  every `$ref` bundled under `$defs`, so it is published as the API describes it; the server
  enforces the field constraints before any request is made.
- `base_url:` names the setting that holds the address (otherwise the document's first `servers`
  url is used, and it must be absolute and free of `{variables}`); `auth_setting:` names the setting
  whose value is sent on every request. The header defaults to `Authorization` and its scheme to
  `Bearer`; `auth_header:` and `auth_scheme:` override them. The base and auth settings must always
  have a value, so they cannot be `optional: true`.
- A call makes the HTTP request and answers the text `{"status": <code>, "body": <parsed JSON or
  text>}`. A 2xx answer is the result; any other status is the same text as an error result
  (`isError: true`), because a failed call is something the model can read and react to. `get`,
  `head` and `options` are annotated `read_only`, `put` and `delete` `idempotent`, and all are
  `open_world`. There is no sandbox and no address guard: the tool calls whatever address the
  setting holds.
- JSON bodies only, `#/components/schemas/Name` references only, and each parameter's default
  style only (path and header `simple`, query `form`); anything else is a compile error that names
  the operation. `N-OPENAPI` names the tools that were made and `W-OPENAPI-AUTH` warns when secured
  operations have no `auth_setting:`. See `examples/shopkit.rmcp.rb` and `make e2e-shopkit`.
