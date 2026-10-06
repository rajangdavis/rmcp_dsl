# Examples

The example servers that ship with the repository.

_See also: [README](../README.md)._

| File | Shows |
|------|-------|
| `add.rmcp.rb`, `arith.rmcp.rb` | a minimal server; checked integer arithmetic and Ruby rounding |
| `textkit.rmcp.rb` | string tools |
| `listkit.rmcp.rb` | lists, nil-able values, `case`, character methods, blocks, guard clauses, ranges, slicing |
| `notekit.rmcp.rb` | annotations, field constraints, optional fields, `instructions`, a prompt, a resource |
| `formkit.rmcp.rb` | list fields with size limits, a nested object, defaults, `format` |
| `httpkit.rmcp.rb` | the same kind of server over streamable HTTP (`transport :http, port: N`) |
| `guide.rmcp.rb` | a server with no tools: only a prompt and a resource; server info, a two-message prompt, icons |
| `jsonkit.rmcp.rb` | a binding's own type (`Json::Value`) as a tool field, a local and a structured result |
| `taskkit.rmcp.rb` | tasks: `task: true` returns a task handle to clients that declared the extension |
| `contentkit.rmcp.rb` | image, audio, resource-link and embedded-resource blocks in tool results |
| `pathkit.rmcp.rb` | resource templates with `{+path}`, `{a,b}`, `{x*}` and `{?q,limit}` |
| `livekit.rmcp.rb` | resource subscriptions and update / list_changed notifications from tools |
| `pagekit.rmcp.rb` | paged lists (`page_size:`) |
| `configkit.rmcp.rb` | settings from the environment: required, defaulted, optional and secret |
| `schemakit.rmcp.rb` | a hand-written `input_schema:` checked against the fields |
| `apikit.rmcp.rb` | settings, a secret and an HTTP client binding calling a local API |
| `shopkit.rmcp.rb` | one tool per operation of an OpenAPI document (`shopkit.openapi.json`), with settings for the address and the key |
| `mapkit.rmcp.rb` | typed maps: `map(:i64)`, `map(list(:string))`, `map(:Member)` and `map(map(:i64))` as input and output; `tally`, `fetch`, `merge`, `select` |
| `statkit.rmcp.rb` | structured output: `output` structs, nested outputs, `result(...)` |
| `logkit.rmcp.rb` | a tool body that sends `log(level, message)` under `feature :logging` (deprecated by SEP-2577) |
| `rootskit.rmcp.rb` | roots: `feature :roots` and a body's `roots()` asking the client for its roots (deprecated by SEP-2577) |
| `samplingkit.rmcp.rb` | sampling: `feature :sampling` and a body's `sample(prompt, max_tokens:, ...)` asking the client's LLM (deprecated by SEP-2577) |
| `elicitation.rmcp.rb` | elicitation: a body asks the client for input with `elicit(message, schema: {...})` and reads the action and content |
| `webkit.rmcp.rb` | a request guard written in Ruby with helpers and the `Html`, `Url` and `Net` bindings |
| `webpeek.rmcp.rb` | fetch and read pages with curl through `cmd_fn`, no guard |
| `fetchkit.rmcp.rb` | the same job with hand-written Rust for the guard (`examples/rust/guard.rs`) |
| `bindings.rmcp.rb`, `injected.rmcp.rb`, `hooked.rmcp.rb`, `exec.rmcp.rb` | bindings, inline Rust, a Rust file, subprocesses |

`webpeek.rmcp.rb` has no address guard, so use it only where reaching private addresses is fine. `webkit.rmcp.rb`
and `fetchkit.rmcp.rb` refuse non-public addresses, pin curl to the address they checked, and label results as
untrusted content.
