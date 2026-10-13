# Bindings

Typed Rust-backed functions for a project, plus injected Rust and subprocesses.

_See also: [README](../README.md)._

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
Types are `String`, `Float`, `I32`, `I64`, `T::Boolean`, `T::Array[String]`, `T::Array[I64]`,
`T::Array[Float]`, and `T.nilable` of those. A nil-able parameter arrives as an owned Option, and a call may
pass `nil`, a plain value or a nil-able one. A params list field can take a `default:` list (`default: []`),
so the body always has a list. A binding's opaque type (`class Value < RmcpDsl::Opaque`) is owned by the module that
declares it, so a second binding cannot name it — keep the type and the functions that use it in one binding.

A **record** is an opaque type that also lists its fields, after its `type_rust` line:

```ruby
class Row < RmcpDsl::Opaque
  type_rust "rows::Row", wire: true
  field :text, String
  field :href, T.nilable(String)
  field :rank, I64
end

sig { params(count: I64).returns(T::Array[Row]) }
```

A body may read a field (`row.text`, `rows.first&.href`) but not set one or build a record: records come from the
binding's functions. A list of them (`T::Array[Row]` in a sig, `list(Rows::Row)` as a field, which needs
`wire: true`) takes the methods a list of params objects takes (`each`, `map`, `select`, `find`, `first`, ...).
Field types are the ones above; a record cannot hold another binding type yet. The generated server reads each
field at its declared type in a check function, so a Rust struct that drifts from the declaration fails the build
at the `field` line, and the record must be `Clone`.
`rmcp_dsl skill` explains the format with a worked example.

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

A `rust_fn`'s declared name is the Rust function's own name: `rust_fn :to_snake, args: [:string], returns: :string, from: :loud`
finds `fn to_snake` inside the `loud` module (the `rust_file` with `as: :loud`), and `rust(:to_snake, ...)` is how a
body calls it — so the declared name must match the Rust function exactly. `returns:` takes the helper types, so
`returns: :string?` (or `:i64?`, `:string_list?`, ...) declares a function returning `Option<...>`, and a body handles the
nil as with any nil-able value (`rust(:reply, text) || "no reply"`) instead of agreeing on a sentinel like `""`.

`rust "expr", async: true` on a binding method, or `rust_fn ... async: true`, declares an `async fn`: its
`returns:`/sig is the eventual value, and a body that calls it is compiled `async fn` and awaits the result
(with `?` when the callee can fail). The template is the async implementation, so put the `await` inside it.
A Ruby-bodied binding has no async context: `async: true` belongs on `rust "..."` only. `async: true` on
`cmd_fn`/`script_fn` is refused, because a subprocess is blocking.

rmcp requires a tool's future to be `Send`, and the compiler never boxes one: an async wrapper is a plain
`async fn`, so rustc's ordinary `Send` obligation applies. A non-`Send` value held across an `.await` in a
template (a `std::sync::MutexGuard`, an `Rc`, a `RefCell` borrow) makes the future non-`Send`, and the
generated tool fails to compile with rustc's `Send` error; the DSL cannot see into hand-written Rust, so
this is fixed in the template, not refused by the DSL.

A body calls them as `rust(:name, args)`. Subprocess arguments are separate argv entries or stdin, never
spliced into shell text. The server runs the program with a 10 s timeout, a 1 MB output cap and only `PATH`
in its environment. There is no sandbox. Every use prints a notice (`N-RUST-INJECTED`, `N-EXEC-INJECTED`)
so you can see how much of a server is not Ruby. See `examples/injected.rmcp.rb`, `hooked.rmcp.rb`, `exec.rmcp.rb`.
