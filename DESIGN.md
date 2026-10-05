# rmcp_dsl: how the compiler is built

Pipeline: `server.rb` is parsed with `Prism.parse_file` and never executed. `Reader` walks it
against the signature table (`SIG`), `Body` turns each tool body into typed Rust text, `Emit`
writes `Cargo.toml` and `src/main.rs`. Every error is `FILE:LINE:COL: message`.

    server.rb --Prism--> Reader (SIG) --> IR hash --> Emit --> crate
                           '--> Body (types, shims, regexes, injected calls)

## Modules (`lib/rmcp_dsl/`)
- `schema.rb`: `SIG`, the one table that says what each DSL call accepts (enclosing call,
  argument names and kinds, keywords, block kind). Also the Rust-keyword and identifier rules.
- `reader.rb`: validates every call against `SIG`, builds the IR, collects crates, items and
  `rust_fn` signatures, then lowers tools after all declarations are known.
- `body.rb`: the expression transpiler. Returns `[rust, type, atomic]`; types are `:i32 :i64
  :f64 :bool :string :str :int :regex :strs`. Deny by default: an unknown node is an error.
- `regex_translate.rb`: pure Ruby-regex to Rust-`regex` translation; rejects what differs.
- `emit.rb`: IR to text. No Prism from here on.
- `notify.rb`: warnings and notices, gated only by environment variables.

## Decisions that shaped it
- Ruby names are the default; behaviour follows the receiver's type. A native Ruby `strip`
  keeps Ruby's rules (and warns); the Rust-typed `Rust::Str#strip` in the test shims follows
  Rust's `trim()`. Warnings never change generated code (SPEC.md 9.3, 9.4).
- The shim catalog (`spec/shims/*.yml`) is the contract: each method form has a Rust
  template and literal examples that run against real Ruby (`make test-ruby`) and real Rust
  (`make test-diff`).
- Structure is enforced twice: Sorbet checks nesting, keywords and types against the
  generated `rbi/dsl.rbi`; `--check` checks values and bodies. Both derive from `SIG`.
- Injected Rust (tier 2): `rust_crate`, `rust_item`, `rust_fn`, called as `rust(:name, ...)`.
  The signature is checked here; the Rust is checked by cargo. Each `rust_item` raises the
  notice `N-RUST-INJECTED` with its line count. `rust_file` copies an existing `.rs` file into
  the crate as a module (`rust_fn ..., from: :module`); its path is confined to the DSL file's folder.
- Bindings (`bindings/*.rb`, parsed with Prism, never run by the compiler): a Ruby stand-in per function
  with a `sig`, a required Ruby body, and an optional `rust "..."` template. No template: the body is
  compiled. Template: Rust implements it and the Ruby body is the reference tests compare against.
  `lib/rmcp_dsl/bindings.rb` is the loader; `Reader#add_bindings`/`lower_bindings` wire it in;
  `Body#binding_call`/`lower_def` check calls and compile Ruby-bodied methods; `Emit.binding_fn` writes
  one typed wrapper per function used.
- Subprocess escape hatch: `cmd_fn` and `script_fn` register an extern returning `:string` and emit
  a wrapper over one shared `run_subprocess` helper (argv entries or stdin, never shell text;
  10 s timeout, 1 MB cap, env reduced to PATH). Embedded engines were ruled out for now.
- The MCP handshake uses an explicit `#[tool_handler(router = Self::tool_router(), name,
  version)]`. The `server_handler` shortcut leaves the server named `rmcp` (rmcp-macros 3.5.0).

## Verified on the owner's host (2026-10-03/04, ruby 4.0.7, rustc 1.99)
- The generated crates build against rmcp 3.5.0 and answer MCP `initialize`, `tools/list`
  and `tools/call` (`make e2e`, `make e2e-textkit`).
- Sorbet accepts the examples against the generated stub (`make typecheck`).
- 61 Ruby shim tests and 59 generated Rust tests agree (`make check`).
- The Prism accessors all three early designs guessed from memory are correct.

## Not verified or not built
- Run and passing: e2e-injected, e2e-hooked, e2e-exec (quick). Written but not run yet:
  e2e-exec-slow (timeout, output cap) and e2e-fetchkit (guard, redirects, failure paths).
- fetchkit runs tool bodies that block (DNS, curl) inside synchronous tool functions; moving
  them to `spawn_blocking` is a known follow-up if concurrency matters.
- Integer arithmetic on i32/i64 is overflow-checked and `/` `%` round down like Ruby; a `Rust::Int32(...)` or
  `Rust::Int64(...)` operand makes the operation truncate like Rust. Written 2026-10-04, `make e2e-arith` not run yet.
- Refusal messages are tested (`test/test_refusals.rb`). Still no automated tests for the notification
  gates or the catalog/transpiler consistency check (SPEC.md layers L6, L8).
- Strictness (2026-10-04): unused `cmd_fn`/`script_fn`/`rust_fn`, unused `params`, unread locals and
  unread block parameters are compile errors, not rustc warnings.
- Prompts, resources, optional fields, and errors as MCP errors are not supported.
- Not packaged as a gem. `exe/rmcp_dsl` and `lib/` already follow the gem layout.
