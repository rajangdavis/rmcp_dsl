# Development

Building and extending the compiler: the make targets, the tree layout and the design notes.

_See also: [README](../README.md)._

## Makefile

```sh
make check-fast     # rbi-check, typecheck, test-ruby (no Rust or example builds)
make check-build    # test-ruby-rust, test-diff (the generated-Rust suites)
make check-e2e      # the e2e of listkit, notekit, logkit, webkit, guide, formkit, statkit, httpkit, lsp, mapkit, jsonkit, taskkit, contentkit, pathkit, livekit, pagekit, configkit, schemakit, apikit, shopkit
make check          # check-fast, check-build and check-e2e
make test-ruby      # Ruby tests: shim catalog against real Ruby, refusals, bindings, emitted Rust text
make test-ruby-rust # L5 in Ruby: build a generated crate and drive it (elicitation, roots, sampling)
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
- Every cargo invocation shares one target dir (`CARGO_TARGET_DIR=target/`), so rmcp and its
  dependencies compile once for the whole suite instead of once per generated crate.

## Layout

| Path | What |
|------|------|
| `exe/rmcp_dsl` | the command |
| `lib/rmcp_dsl/lsp/` | the language server: analysis, hover, inlay hints, completion, protocol |
| `lib/rmcp_dsl/` | signature table, reader, body transpiler, regex translator, emitter, bindings loader, error mapping, notifications, skill generator |
| `examples/bindings/` | example bindings (typed Rust-backed functions) the examples use; a project keeps its own `bindings/` next to its DSL files |
| `spec/shims/string.yml` | the shim catalog: each string method, its Rust template, literal examples |
| `rbi/` | generated Sorbet description of the DSL (do not edit `dsl.rbi`) and a stub for a prism RBI bug |
| `examples/` | the servers listed in [Examples](examples.md) |
| `bin/` | `gen_rbi`, `gen_shim_tests`, `probe` |
| `test/` | Ruby tests, `refusals/`, and the end-to-end MCP scripts |
| `shimcheck/` | scratch crate holding the generated Rust tests |

## More

- [SKETCH.md](../SKETCH.md): design notes and decisions
- [SPEC.md](../SPEC.md): test plan, shim catalog format, notifications, regex rules
- [DESIGN.md](../DESIGN.md): the compiler's structure and what is unverified
