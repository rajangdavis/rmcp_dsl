# How much of MCP is covered

_See also: [README](../README.md)._

The target is the server side of MCP as the rmcp 3.5.0 SDK exposes it. ✓ works and is tested, ◐ partly,
✗ not done. The aim is to cover as much of the API as is sensible; this table is the to-do list.

**Tools**

| | |
|---|---|
| ✓ | list and call; name; description; JSON input schema from the fields |
| ✓ | field constraints, enforced by the server (`min max exclusive_min exclusive_max multiple_of min_length max_length pattern enum min_items max_items`) |
| ✓ | optional fields, defaults, formats, list fields (strings, integers and floats), lists of objects (`list(:Address)`), typed maps with scalar, object or nested-map values (`map(:i64)`, `map(:Address)`, `map(map(:i64))`), required and optional nested objects |
| ✓ | annotations (`title read_only destructive idempotent open_world`); error results (`isError`); text content |
| ✓ | a server with no tools |
| ✓ | structured output: `output` structs published as `outputSchema`, results sent as `structuredContent` |
| ✓ | content blocks: text, image, audio, resource links and embedded resources (text or blob), alone or several in one result, with `audience:` and `priority:`; literal base64, MIME types and URIs are checked when compiled |
| ✓ | tool title and icon |
| ✓ | `_meta`: a static JSON literal with spec-checked keys (`meta:`) |
| ✓ | task support (`task: true`): the `io.modelcontextprotocol/tasks` extension, so a client that declared it gets a task handle, polls `tasks/get` and may `tasks/cancel`; others get the plain result |
| ✓ | `tools/list_changed`: a tool body may `hide_tool(:name)` or `show_tool(:name)` to change the advertised list at run time; clients are told with `notifications/tools/list_changed`, hidden tools are left out of `tools/list` and refused by `tools/call` |

**Prompts**

| | |
|---|---|
| ✓ | list and get; string arguments, required or not, described |
| ✓ | several messages in order, user and assistant roles; prompt title and icon |
| ✓ | argument completion: a prompt argument with `enum:` offers the values that start with what was typed |
| ✓ | `_meta` (`meta:`) |
| ✓ | image or resource content in messages |
| ✓ | argument completion beyond `enum:`: a `complete:` helper on a `:string` field, or a `complete` block on a prompt |

**Resources**

| | |
|---|---|
| ✓ | static text: list and read, with title, description and MIME type |
| ✓ | binary (blob) resources and several contents per read: a body returns `text(s)`/`blob(base64)` contents, alone or in an array, each with `uri:` and `mime_type:` |
| ✓ | resource icon, annotations (`audience:`, `priority:`) and `_meta` (`meta:`), also on templates |
| ✓ | URI templates (`notes://{id}`, RFC 6570 with `{+path}`, `{a,b}`, `{x*}` and `{?q,limit}`): `resources/templates/list`, reads with percent-decoding, completion of arguments (`enum:`, `complete:` or a `complete` block, `ref/resource`) |
| ✓ | resource size (`size:`), checked against the body when that is a plain string literal; a `text(...)`/`blob(...)` or multi-content body is not checked |
| ✓ | subscriptions and `resources/updated` (`updates:` on a tool), `resources/list_changed` (`resource_list_changed: true`), over `subscriptions/listen` and the earlier `resources/subscribe` |
| ✓ | pagination of tools, prompts, resources and templates (`page_size:` on the server, opaque cursors, invalid cursors are `-32602`) |

**Server and transport**

| | |
|---|---|
| ✓ | name, version, `instructions`; capabilities for tools, prompts and resources; ping |
| ✓ | server title, description, website and icon |
| ✓ | settings read from the environment at startup (`setting`, with `default:`, `optional:` and `secret:`); a missing required one stops the server with a clear message |
| ✓ | an HTTP client binding for tools that call an API (`examples/bindings/http.rb`) |
| ✓ | cooperative cancellation: rmcp cancels the request's token on `notifications/cancelled`, and a tool body that checks `cancelled?` around its awaits can stop early; blocking escapes (`cmd_fn`/`script_fn`, blocking bindings) run to completion |
| ✓ | async functions: a `rust_fn` or binding declared `async: true` is an `async fn`, and a helper, tool, prompt or resource body that calls one is compiled `async fn` and awaits it (the declared type is the eventual value; async is inferred) |
| ✓ | stdio transport (`transport :stdio`) |
| ✓ | streamable HTTP (`transport :http, port: 8080`): rmcp's own default service, sessions and host check, on 127.0.0.1 at `/mcp` |
| ✓ | Bearer-token auth for HTTP (`transport :http, port: 8080, auth_setting: :api_token`): a layer in front of `/mcp` answers 401 with `WWW-Authenticate: Bearer` unless the request carries the secret setting's value |
| ✓ | OAuth resource server for HTTP (`transport :http, port: 8080, oauth_issuer: :issuer, oauth_audience: :audience`, optional `oauth_resource:`): `/mcp` accepts only a JWT the issuer signed (RS256 or ES256, key from its JWKS found by RFC 8414 or OpenID Connect discovery) for that audience, and `/.well-known/oauth-protected-resource` (RFC 9728) says where to get one |
| ✗ | The `StreamableHttpServerConfig` options (hosts, origins, stateless mode), and refresh or introspection of tokens; rmcp 3.5.0 has no SSE or WebSocket server transport |
| ✓ | progress notifications from a tool body (`progress(value, total:, message:)`), sent only when the client supplied a progress token |
| ✓ | logging (`feature :logging`): advertises the capability, answers `logging/setLevel`, and a tool body's `log(level, message)` sends `notifications/message`; deprecated by SEP-2577 and opt-in, so the emitted call is scoped with `#[allow(deprecated)]` |
| ✓ | the request context in a tool body: `client_name`, `client_version`, `protocol_version`, `request_id`, `progress_token`, `cancelled?` |
| ✓ | elicitation from a tool body (`elicit(message, schema: { ... })`): the body asks the client for input and reads the action (`accept`, `decline` or `cancel`) and the content; the rmcp `elicitation` feature is enabled only when it is used |
| ✓ | roots (`feature :roots`): a tool body's `roots()` asks the client for its roots (`roots/list`) and reads each root's `uri` and nil-able `name` with `roots().map { |root| ... }` / `.each`; deprecated by SEP-2577 and opt-in, so the emitted call is scoped with `#[allow(deprecated)]` |
| ✓ | sampling (`feature :sampling`): a tool body's `sample(prompt, max_tokens:, system:, temperature:, stop:)` asks the client's LLM for a completion (`sampling/createMessage`) and reads the nil-able `text`, the `model`, the `role` and the nil-able `stop_reason`; deprecated by SEP-2577 and opt-in, so the emitted call is scoped with `#[allow(deprecated)]` |
| – | the rmcp client side is out of scope: this tool writes servers |

**Input and output schemas.** Typed maps with string, integer, float, boolean, list, object (`map(:Address)`) and
one-level nested-map (`map(map(:i64))`) values are done, and so are lists of objects (`list(:Address)`). Missing:
collections nested more than one level deep (a map of maps of maps, or a map of lists of objects). A hand-written
schema (`input_schema:`) is checked against the fields.

**Body language.** Hash literals exist as typed maps (string keys, one value type) and are read-only: `map`,
`select`, `reject` and `each` take a `|k, v|` block: `map` returns a list built from the block, `select`/`reject`
build a new map of the same value type, and `each` runs the block for its effects and returns the map; in-place
changes are not supported.

Planned order: richer inputs, structured output, metadata, content, tasks and resource notifications, request
context, progress and elicitation (done, see above), then streamable HTTP and auth. Logging, roots and
sampling are done as deprecated, opt-in features: declare `feature :logging` to use `log` and answer
`logging/setLevel`, `feature :roots` to use `roots()`, and `feature :sampling` to use
`sample(prompt, max_tokens: ...)`.
