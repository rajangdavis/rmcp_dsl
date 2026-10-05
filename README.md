# rmcp_dsl

Write an MCP server in a small, strict Ruby DSL. `rmcp_dsl` reads the file (it is parsed with
Prism, never run) and writes a Rust crate that uses the [rmcp](https://crates.io/crates/rmcp)
SDK. Build the crate with cargo to get a server that speaks MCP over stdio.

The tool bodies are ordinary-looking Ruby: strings, lists, integers, `if`, `case`, blocks, guard
clauses, helper functions. The compiler translates them to Rust that behaves the way the Ruby reads,
refuses what it cannot translate faithfully, and reports mistakes with a file, line and column.
Parts that need a Rust library (HTML parsing, URLs, DNS, case conversion) come in through typed
bindings, so a server can be written without hand-writing Rust.

Status: a working proof of concept, not a released tool. Tested with rmcp 3.5.0.

## Requirements

- Ruby 4.0.7 (see `.tool-versions`) with the `prism` gem (`bundle install`)
- Rust (rustc and cargo), only to build what the compiler writes
- Optional: `sorbet` (`srb tc`) for the structure check of the DSL files

## Quick start

```ruby
# examples/add.rb
# typed: true
server "calculator", version: "0.1.0" do
  params :CalcParams do
    field :a, :i32
    field :b, :i32
  end

  tool :add, params: :CalcParams, description: "Add two integers" do
    body do |a, b|
      (a + b).to_s
    end
  end

  transport :stdio
end
```

```sh
ruby exe/rmcp_dsl check examples/add.rb      # validate only; writes nothing
ruby exe/rmcp_dsl build examples/add.rb      # write build/add and run cargo build
ruby exe/rmcp_dsl run examples/add.rb        # build, then serve MCP on stdio
```

## The command line

| Command | Does |
|---------|------|
| `rmcp_dsl check FILE [--format json]` | Parse, type-check, report notifications; write nothing. `--format json` prints one document for editors and agents: `{ok, file, notes}` or `{ok: false, error: {file, line, col, message, suggestions}}`. Exit 1 on failure. Compile errors name the valid choices and suggest the nearest name when one looks like a typo (``unsupported method `upcas` ...; did you mean `upcase`?``); `suggestions` carries those names. `--types` (with `--format json`) adds `types`: `[{line, col, end_line, end_col, kind, type, name?}]` for every parameter, local and expression the compiler typed (lines and columns are 1-based, `end_col` exclusive, types read like Sorbet: `String`, `Integer (i64)`, `T.nilable(String)`), which is what an editor needs to show types in a body. |
| `rmcp_dsl lsp` | Run a language server on stdio for DSL files (see "Editor support"). |
| `rmcp_dsl rbi FILE... [-o DIR]` | Write Sorbet signatures for the helpers the files declare (default `sorbet/rbi/rmcp_dsl/dsl_helpers.rbi`), so DSL files can be `# typed: true`. |
| `rmcp_dsl build FILE [-o DIR] [--release] [--emit-only]` | Write the crate (default `build/NAME`) and run `cargo build`. A rustc error inside generated code is printed at the DSL line that produced it. |
| `rmcp_dsl run FILE [-o DIR] [--release]` | Build, then start the server on stdio. |
| `rmcp_dsl skill [-o DIR]` | Write an agent skill folder (`rmcp-dsl/SKILL.md` plus references) that teaches the DSL. The reference pages are generated from the compiler, so they match the installed version. |
| `--warn SPEC`, `--notice SPEC` | Choose which notifications are printed (`all`, `none`, or codes). |
| `--version` | Print the version. |

The original form still works: `rmcp_dsl FILE -o DIR`, `--check`, `--dump-ir`.

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

- **Fields** take `description:`, `optional:`, `default:`, and JSON schema constraints: `min:`/`max:` on
  numbers, `min_length:`/`max_length:`/`pattern:`/`enum:` on strings, `min_items:`/`max_items:` on lists.
  The generated server also enforces the constraints and answers a violation with an error result, because
  a schema is only advice to the client. An optional field is nil-able in the body (`limit || 10`); a
  field with a `default:` is always present, and the default is advertised in the schema.
- **Structured results.** `output :Stats do field :count, :i64 ... end` declares a typed result (fields take
  `description:` and `optional:`, and may nest another output); `tool :stats, output: :Stats` returns it, and
  the body ends in `result(:Stats, count: 3, ...)` with every field given once and typed. Clients receive
  `structuredContent` (plus the same JSON as text) and the tool list publishes an `outputSchema`. Errors
  (`raise`) stay `isError` results.
- **Typed maps** are objects with string keys and one value type: `field :counts, map(:i64)`, `map(:string)`,
  `map(:f64)`, `map(:bool)`, `map(list(:string))`. The schema says `additionalProperties`. In a body, `m["k"]`
  is nil-able (use `|| default`), and `fetch`, `key?`, `keys`, `values` (string or integer values), `size`,
  `empty?` and `merge` work; a literal is `{ "a" => 1 }` (string keys, values of one type; `{a: 1}` is refused
  because a symbol is a different key in Ruby) and `items.tally` counts a list of strings. A map is a Rust
  `BTreeMap`, as serde_json's own objects are, so keys come back sorted, not in insertion order. Maps are
  read-only: nothing changes one in place. `list(:string)` is the same as `:string_list`. Anything more
  complicated than these basic JSON shapes belongs in a binding.
- **A binding's own types** carry anything more complicated than basic JSON. A binding declares one with
  `class Value < RmcpDsl::Opaque; type_rust "serde_json::Value", wire: true; end` (see `examples/bindings/json.rb`).
  The DSL holds a value of it (`doc = Json.parse(text) || raise("not JSON")`), passes it to that binding's functions
  and may return it; it cannot look inside. `field :doc, Json::Value` makes it a tool field or result field,
  which needs `wire: true` (the Rust type is serde Serialize and Deserialize and schemars JsonSchema); without it a
  value lives only in bodies. See `examples/jsonkit.rb`.
- **`meta:`** on a tool, prompt or resource is static metadata sent as `_meta`: a JSON object written as a
  literal (`meta: { "com.example/tier" => "free" }`). Keys follow the MCP rules (an optional reverse-DNS prefix such as
  `com.example/`; prefixes the spec reserves, and the keys `progressToken`, `traceparent`, `tracestate` and
  `baggage`, are refused at compile time).
- **Field types** are `:string :i32 :i64 :f64 :bool`, lists (`:string_list`, `:i64_list`), and a nested
  object: name another `params` declared above (`field :address, :Address`) and read it in the body as
  `address.city`. `format:` (`:uri :email :date_time :date :uuid :hostname :ipv4 :ipv6`) is advice to the
  client and is not checked by the server.
- **Tool annotations** (`title:`, `read_only:`, `destructive:`, `idempotent:`, `open_world:`) tell a
  client whether a tool is safe to call without asking.
- **`instructions:`** on the server is the text a model reads about how to use it. `title:`, `description:`,
  `website_url:` (http or https) and `icon:` (an http, https or `data:` URI) describe the server to a client.
  Tools, prompts and resources take `icon:` too, and prompts and tools take `title:`.

- **Prompts** (`prompt :name, params: :P, description: "..." do body ... end`) are tool-shaped templates
  whose body returns the text of one user message. A prompt argument with `enum:` is also completed: the
  server advertises the `completions` capability and answers `completion/complete` with the values that start
  with what was typed (at most 100, with `total` and `hasMore`); a prompt or argument that does not exist is
  `-32602`, as the MCP spec says, and an argument with nothing to offer gets an empty answer. For a conversation, use `message :assistant do ... end`
  and `message :user do |topic| ... end` blocks, in order, instead of `body`. MCP passes prompt arguments as strings, so a prompt's
  params may only have `:string` fields.
- **Resources** (`resource :guide, uri: "notekit://guide", mime_type: "text/markdown" do body ... end`) are
  readable text at a URI; the body takes no parameters and runs on every read. `audience: ["user"]` and
  `priority: 0.5` (0 to 1) tell a client who a resource is for and how much it matters.
- **Resource templates** are resources whose `uri:` has `{placeholders}` (RFC 6570 level 1, plain `{name}` only):
  `resource :note, uri: "notes://{id}", params: :NoteParams do body do |id| ... end end`. Each placeholder needs a
  `:string` field of that name in `params:`, and the field's `pattern:`, `enum:` or `min_length:` checks the value.
  They are listed by `resources/templates/list` (`uriTemplate`), not `resources/list`. A placeholder matches
  everything up to the next `/`, `?` or `#` (it may be empty, as RFC 6570 allows) and is percent-decoded. The
  compiler refuses unclosed or empty braces, operators such as `{+path}` or `{?q}`, a placeholder with no field
  (or a field with no placeholder), and two resources that could match the same uri. At run time a bad escape or
  a violated constraint is `-32602`, a uri that matches nothing is not-found, and a `raise` in the body also
  means the resource does not exist (`-32002`, or `-32602` for clients on protocol 2026-07-28; rmcp chooses),
  with the uri in `data`. An `enum:` field is also completed (`completion/complete` with `ref/resource`).

`examples/notekit.rb` and `make e2e-notekit` cover most of this; `examples/formkit.rb` covers lists, nested
objects, defaults and formats; `examples/guide.rb` is a server with no tools, only a prompt and a resource.

## What a tool body may contain

Ordinary Ruby from a deliberately small subset. Anything else is a compile error that says what to use
instead. `rmcp_dsl skill` writes the complete, generated reference; the outline:

- **Types:** `:i32`, `:i64`, `:f64`, `:bool`, `:string`, lists of strings or integers, and fields of a
  nested object (`address.city`; an object cannot be put in a string, read its fields).
- **Syntax:** literals, locals (`name = expr`, no reassignment), arithmetic and comparisons, `&& || !`,
  `if`/`elsif`/`else`, `unless`, ternary, `case`/`when`, string interpolation, guard clauses
  (`return "x" if cond`, `raise "msg" unless cond`), and blocks with one parameter.
- **Strings:** `upcase downcase strip capitalize length split partition chars lines reverse tr delete
  squeeze index start_with? end_with? include? empty? match? gsub sub to_i`, slicing `s[start, len]` and
  `s[i]`, `s * n`, and `Integer(text, 10)`. `gsub`/`sub` take a string or regex literal, or a block.
- **Lists:** `split`, array literals, `n.times`, `a.upto(b)`, ranges `(a..b)`, and `map select reject
  find any? all? count sum min max sort uniq reverse first last [] join include? empty?`. Blocks may use
  arithmetic, `to_i`, `raise` and `return`.
- **Nil-able values.** Methods that return nil in Ruby (`first`, `last`, `xs[i]`, `index`, optional fields,
  nil-able binding results) must be used through `|| default`, `|| raise("msg")`, `.nil?` or `.to_s`, so a
  missing value is never silently used.
- **Errors.** `raise "msg"` and integer overflow end the call with an error result (`isError: true`).
  `return value` ends it with that string, even from inside a list block.
- **Integers follow Ruby:** `/` rounds down and `%` takes the sign of the divisor. `Rust::Int32(a) / b`
  opts into Rust's truncating behaviour. Arithmetic is overflow-checked and a result that does not fit
  comes back as an error that says what, where and how to fix.
- The last expression is the result and must be a string.

The DSL is strict on purpose so the file says exactly what the server does and the generated Rust stays
warning-free. Unused locals, block parameters, declarations, helpers and params are all compile errors.
Regex literals are translated to Rust's `regex` crate; features the engines disagree on (lookaround,
backreferences, `\h`, `\Z`, possessive quantifiers) are rejected.

`make probe` runs about forty one-line bodies through the compiler and prints which Ruby it accepts today.

## Helpers

Logic that more than one tool needs goes in a helper, with its types written out:

```ruby
helper :checked_host, args: [:string], returns: :string do |url|
  raise "not a valid URL: #{url}" unless Url.valid?(url)
  (Url.host(url) || raise("URL has no host")).delete("[]")
end

tool :host, params: :UrlParams, description: "The checked host" do
  body do |url|
    checked_host(url)
  end
end
```

Types are `:string :i32 :i64 :f64 :bool :string_list :i64_list`, and nil-able results such as `:string?`.
A helper can only call helpers declared above it, so recursion cannot happen. A failure inside a helper
becomes an error result in the caller; a helper that cannot fail compiles to a plain function. A helper
that nothing calls is an error. Sorbet cannot know names declared in the DSL, so `rmcp_dsl rbi FILE...` writes
their signatures to `sorbet/rbi/rmcp_dsl/dsl_helpers.rbi` (`make rbi-helpers`; `make check` fails if it is stale)
and files that call helpers stay `# typed: true`. Two files declaring one helper with different types are
refused. The compiler checks every call regardless. `examples/webkit.rb` uses three.

## Bindings

A binding is a Ruby file that gives the compiler a typed function backed by a Rust crate (or compiled from
Ruby). The compiler ships none: they belong to the project. To use one, put a `bindings/` folder in the same
directory as the DSL file, with `bindings/NAME.rb` in it; `use_bindings :name` loads it from there (nothing is
searched beyond that folder), and a body calls it as `Module.method(args)`. A missing file is an error that names
the path it looked for.

`examples/bindings/` holds working bindings that the examples use, and that you can copy:

| Binding | Backed by | Functions |
|---------|-----------|-----------|
| `Heck` | `heck` | `snake_case kebab_case upper_camel_case` |
| `Words` | compiled from Ruby | `shout bracket` |
| `Html` | `scraper` | `select attr valid_selector?` |
| `Url` | `url` (WHATWG) | `valid? scheme host port path join credentials?` |
| `Net` | `std::net` | `addresses public_address?` |

**A binding never fails by itself.** A nil-able return type (`T.nilable(String)`,
`T.nilable(T::Array[String])`) means "does not exist" or "does not parse", and the server decides what that
means: `Html.select(page, css) || []` to carry on, `|| raise("invalid selector")` to fail, `.nil?` to test.
Types are `String`, `Float`, `I32`, `I64`, `T::Boolean`, `T::Array[String]`, `T::Array[I64]`, and
`T.nilable` of those as a return type. `rmcp_dsl skill` explains the format with a worked example.

Each method has a `sig`, a `rust "..."` template (or a Ruby body that is compiled), and examples. With a
template the Ruby body is the answer key the tests compare the crate against; `no_reference "why"` marks a
function with no Ruby stand-in (an HTML parser, DNS), whose examples are checked only against the Rust.
The compiler only parses bindings; it never runs them.

## Injected Rust and subprocesses

Use Rust or call another program:

```ruby
rust_crate "heck", "0.5"                                 # a Cargo dependency
rust_item <<~'RS'                                        # verbatim top-level Rust
  fn to_snake(s: &str) -> String { use heck::ToSnakeCase; s.to_snake_case() }
RS
rust_fn :to_snake, args: [:string], returns: :string     # its signature, checked by the compiler
rust_file "rust/shout.rs", as: :loud                     # an existing file, copied in as a module

cmd_fn :run_upper, program: "tr", argv: ["a-z", "A-Z"], args: [:string], returns: :string, pass: :stdin
script_fn :run_echo, interpreter: "sh", args: [:string], returns: :string, code: <<~'SH'
  printf '%s' "$1"
SH
```

A body calls them as `rust(:name, args)`. Subprocess arguments are separate argv entries or stdin, never
spliced into shell text. The server runs the program with a 10 s timeout, a 1 MB output cap and only `PATH`
in its environment. There is no sandbox. Every use prints a notice (`N-RUST-INJECTED`, `N-EXEC-INJECTED`)
so you can see how much of a server is not Ruby. See `examples/injected.rb`, `hooked.rb`, `exec.rb`.

## Examples

| File | Shows |
|------|-------|
| `add.rb`, `arith.rb` | a minimal server; checked integer arithmetic and Ruby rounding |
| `textkit.rb` | string tools |
| `listkit.rb` | lists, nil-able values, `case`, character methods, blocks, guard clauses, ranges, slicing |
| `notekit.rb` | annotations, field constraints, optional fields, `instructions`, a prompt, a resource |
| `formkit.rb` | list fields with size limits, a nested object, defaults, `format` |
| `httpkit.rb` | the same kind of server over streamable HTTP (`transport :http, port: N`) |
| `guide.rb` | a server with no tools: only a prompt and a resource; server info, a two-message prompt, icons |
| `jsonkit.rb` | a binding's own type (`Json::Value`) as a tool field, a local and a structured result |
| `taskkit.rb` | tasks: `task: true` returns a task handle to clients that declared the extension |
| `contentkit.rb` | image, audio, resource-link and embedded-resource blocks in tool results |
| `pathkit.rb` | resource templates with `{+path}`, `{a,b}`, `{x*}` and `{?q,limit}` |
| `livekit.rb` | resource subscriptions and update / list_changed notifications from tools |
| `pagekit.rb` | paged lists (`page_size:`) |
| `mapkit.rb` | typed maps: `map(:i64)` and `map(list(:string))` as input and output, `tally`, `fetch`, `merge` |
| `statkit.rb` | structured output: `output` structs, nested outputs, `result(...)` |
| `webkit.rb` | a request guard written in Ruby with helpers and the `Html`, `Url` and `Net` bindings |
| `webpeek.rb` | fetch and read pages with curl through `cmd_fn`, no guard |
| `fetchkit.rb` | the same job with hand-written Rust for the guard (`examples/rust/guard.rs`) |
| `bindings.rb`, `injected.rb`, `hooked.rb`, `exec.rb` | bindings, inline Rust, a Rust file, subprocesses |

`webpeek.rb` has no address guard, so use it only where reaching private addresses is fine. `webkit.rb`
and `fetchkit.rb` refuse non-public addresses, pin curl to the address they checked, and label results as
untrusted content.

## Notifications

Where Ruby and Rust behave differently, or the compiler cannot see the code, it prints a notification. They
never change the generated code and never fail the build.

| Code | Meaning |
|------|---------|
| `W-STR-STRIP-RUBY` | `strip` keeps Ruby's rules (NUL and ASCII whitespace), spelled out in Rust |
| `W-STR-CAPITALIZE` | Ruby titlecases some characters (for example `ß`); Rust only uppercases |
| `N-RUST-INJECTED` | a `rust_item` or `rust_file` was injected; the compiler does not check its Rust |
| `N-EXEC-INJECTED` | a subprocess runs on every call; no sandbox |
| `N-BINDING` | which binding functions a server uses and what backs them |
| `W-RUST-FN-MISSING` | a `rust_fn` names a function not found in its `rust_file` |

```sh
RMCP_DSL_WARN=none make dsl-check                  # hide warnings
RMCP_DSL_WARN=W-STR-STRIP-RUBY make dsl-check      # show only these codes
```

An unknown code in `RMCP_DSL_WARN`, `RMCP_DSL_NOTICE`, `--warn` or `--notice` is an error.

## Makefile

```sh
make check          # rbi-check, typecheck, test-ruby, test-diff, and the e2e of listkit, notekit, webkit, guide, formkit, statkit, httpkit, mapkit, jsonkit, taskkit, contentkit, pathkit, livekit, pagekit
make test-ruby      # Ruby tests: shim catalog against real Ruby, refusals, bindings, emitted Rust text
make test-diff      # generate a Rust test per catalog and binding example, and run cargo test
make dsl-check      # parse and type-check every example, no output files
make probe          # which body constructs compile today
make e2e-NAME       # build one example and talk MCP to it (webpeek, listkit, notekit, webkit, textkit,
                    #   injected, hooked, exec, exec-slow, fetchkit, arith, bindings)
make e2e            # calculator (and listkit)
make rbi            # regenerate rbi/dsl.rbi from the compiler's signature table
make e2e-lsp        # the language server as a real process over stdio (diagnostics, hover, hints, completion)
make gem-test       # build the gem, install it into a throwaway GEM_HOME, use it from outside the repo
```

- Every string method in the body language has a catalog entry with literal examples. `test-ruby` runs
  them against real Ruby and `test-diff` runs the same examples against the generated Rust, so the two
  must agree. Binding examples are checked against the real crates the same way.
- Every refusal the compiler makes has a file in `test/refusals/` that must be refused with that message.
- `make e2e-listkit` and the others compare the running server's answers with what Ruby returns.

## Editor support

`rmcp_dsl lsp` is a language server for DSL files. It is driven by the compiler, so it knows exactly what the
compiler will accept: no Sorbet or ruby-lsp is needed for it, and it works on unsaved text.

- **Diagnostics** are the compiler's errors, with the valid choices and "did you mean" suggestions, shown as
  you type. A **quick fix** replaces a misspelt name with the suggestion.
- **Hover** shows the inferred type of the parameter, local or expression under the cursor
  (`email: String`, `T.nilable(String)`, `(String) -> String` for a helper), including inside bodies.
- **Hover on the DSL itself:** point at a call name (`tool`, `params`, ...) or its name for a summary (a params
  struct lists its fields, a tool shows its params, output and flags) plus the one-line doc, or at a `keyword:` label
  for that keyword's doc and value.
- **Go to definition** jumps from `params: :Name`, `output: :Name`, a nested `field :x, :Name` or `result(:Name, ...)` to
  the declaration, and from a helper call to `helper :name`. The **outline** lists the server with its params (and
  fields), outputs, tools, prompts, resources, helpers and transport.
- **Inlay hints** show `: Type` after each body parameter in `|email, level|` and after each local.
- **Completion** offers methods valid for the receiver's type after a dot, the tool's fields in `|...|`,
  names in scope, keyword arguments, symbol values (`:string`, `transport :http`, declared `params:` names) and
  declaration snippets. It works on lines that do not compile yet.

Name DSL files `*.rmcp.rb` (the compiler accepts any path) and attach the server to that file type, language
Ruby for highlighting, command `rmcp_dsl lsp`, no arguments, stdio. The same data is available to agents without a
server: `rmcp_dsl check FILE --format json --types`. ruby-lsp cannot do this (as of 0.26 its hover never fires on
local variables, and add-ons have no inlay hint or diagnostic hooks), which is why this is a separate server.
`make e2e-lsp` drives the real process over stdio. Not yet covered: rename, and hints for parameter lists
that span several lines.

**Keeping the editor in step with the DSL.** Every call and keyword has one sentence in `lib/rmcp_dsl/docs.rb`. The
generated skill, completion and hover read it, so a sentence is written once. `test/test_dsl_completeness.rb`
fails when `SIG` gains a call or keyword without a sentence, or when completion stops offering it, so a new MCP
feature cannot ship without its editor support. For a keyword whose values are a fixed set of strings (such as
`audience:`), add them to `Docs::CHOICES` and completion offers them inside `audience: ["`. A list-method typo
(`items.uniqq`) gets a "did you mean" like any other.

## Install

As a gem: `gem build rmcp_dsl.gemspec`, then `gem install rmcp_dsl-0.1.0.gem`, then `rmcp_dsl --help`.
`make gem-test` proves `spec/shims/` shipped and that an installed gem finds a binding next to a file. `rmcp_dsl skill` writes an agent skill folder
(`rmcp-dsl/`) into the current directory, for any agent that reads `SKILL.md`.

## How much of MCP is covered

The target is the server side of MCP as the rmcp 3.5.0 SDK exposes it. ✓ works and is tested, ◐ partly,
✗ not done. The aim is to cover as much of the API as is sensible; this table is the to-do list.

**Tools**

| | |
|---|---|
| ✓ | list and call; name; description; JSON input schema from the fields |
| ✓ | field constraints, enforced by the server (`min max min_length max_length pattern enum min_items max_items`) |
| ✓ | optional fields, defaults, formats, list fields, nested objects |
| ✓ | annotations (`title read_only destructive idempotent open_world`); error results (`isError`); text content |
| ✓ | a server with no tools |
| ✓ | structured output: `output` structs published as `outputSchema`, results sent as `structuredContent` |
| ✓ | content blocks: text, image, audio, resource links and embedded resources (text or blob), alone or several in one result, with `audience:` and `priority:`; literal base64, MIME types and URIs are checked when compiled |
| ✓ | tool title and icon |
| ✓ | `_meta`: a static JSON literal with spec-checked keys (`meta:`) |
| ✓ | task support (`task: true`): the `io.modelcontextprotocol/tasks` extension, so a client that declared it gets a task handle, polls `tasks/get` and may `tasks/cancel`; others get the plain result |
| – | `tools/list_changed`: the tools are fixed when the server is compiled, so the list never changes |

**Prompts**

| | |
|---|---|
| ✓ | list and get; string arguments, required or not, described |
| ✓ | several messages in order, user and assistant roles; prompt title and icon |
| ✓ | argument completion: a prompt argument with `enum:` offers the values that start with what was typed |
| ✓ | `_meta` (`meta:`) |
| ✗ | image or resource content in messages; completion for anything but `enum:` |

**Resources**

| | |
|---|---|
| ✓ | static text: list and read, with title, description and MIME type |
| ✗ | binary (blob) resources; several contents per read |
| ✓ | resource icon, annotations (`audience:`, `priority:`) and `_meta` (`meta:`), also on templates |
| ✓ | URI templates (`notes://{id}`, RFC 6570 with `{+path}`, `{a,b}`, `{x*}` and `{?q,limit}`): `resources/templates/list`, reads with percent-decoding, completion of `enum:` arguments (`ref/resource`) |
| ✓ | resource size (`size:`), checked against the body when that is a plain string |
| ✓ | subscriptions and `resources/updated` (`updates:` on a tool), `resources/list_changed` (`resource_list_changed: true`), over `subscriptions/listen` and the earlier `resources/subscribe` |
| ✓ | pagination of tools, prompts, resources and templates (`page_size:` on the server, opaque cursors, invalid cursors are `-32602`) |

**Server and transport**

| | |
|---|---|
| ✓ | name, version, `instructions`; capabilities for tools, prompts and resources; ping |
| ✓ | server title, description, website and icon |
| ◐ | cancellation (rmcp handles it; not tested against slow tools) |
| ✓ | stdio transport (`transport :stdio`) |
| ✓ | streamable HTTP (`transport :http, port: 8080`): rmcp's own default service, sessions and host check, on 127.0.0.1 at `/mcp` |
| ✗ | OAuth and other auth, and the `StreamableHttpServerConfig` options (hosts, origins, stateless mode); rmcp 3.5.0 has no SSE or WebSocket server transport |
| ✗ | logging (`logging/setLevel`, log messages) and progress notifications |
| ✗ | access to the request context (client info, progress token, cancellation) from a body |
| ✗ | sampling, elicitation and roots (server-to-client requests) |
| – | the rmcp client side is out of scope: this tool writes servers |

**Input and output schemas.** Typed maps with string, integer, float, boolean and list values are done. Missing:
maps of objects or of maps, optional nested objects, lists of floats, lists of objects, exclusive bounds,
`multipleOf`, and a hand-written schema override.

**Body language.** Hash literals exist as typed maps (string keys, one value type). Missing: `each`, blocks on
maps, `=~` (use `match?`), nil-able helper parameters and keyword arguments to helpers, and changing a map in place.

Planned order: richer inputs, structured output, metadata, content, tasks and resource notifications (done, see above), then
progress and request context, streamable HTTP and auth, sampling, elicitation and roots.

## Layout

| Path | What |
|------|------|
| `exe/rmcp_dsl` | the command |
| `lib/rmcp_dsl/lsp/` | the language server: analysis, hover, inlay hints, completion, protocol |
| `lib/rmcp_dsl/` | signature table, reader, body transpiler, regex translator, emitter, bindings loader, error mapping, notifications, skill generator |
| `examples/bindings/` | example bindings (typed Rust-backed functions) the examples use; a project keeps its own `bindings/` next to its DSL files |
| `spec/shims/string.yml` | the shim catalog: each string method, its Rust template, literal examples |
| `rbi/` | generated Sorbet description of the DSL (do not edit `dsl.rbi`) and a stub for a prism RBI bug |
| `examples/` | the servers above |
| `bin/` | `gen_rbi`, `gen_shim_tests`, `probe` |
| `test/` | Ruby tests, `refusals/`, and the end-to-end MCP scripts |
| `shimcheck/` | scratch crate holding the generated Rust tests |

## License

GNU Affero General Public License, version 3 only (`AGPL-3.0-only`). The full text is in `LICENSE`.

## More

- `SKETCH.md`: design notes and decisions
- `SPEC.md`: test plan, shim catalog format, notifications, regex rules
- `DESIGN.md`: the compiler's structure and what is unverified
