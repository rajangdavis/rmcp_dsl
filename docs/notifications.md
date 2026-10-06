# Notifications

_See also: [README](../README.md)._

Where Ruby and Rust behave differently, or the compiler cannot see the code, it prints a notification. They
never change the generated code and never fail the build.

| Code | Meaning |
|------|---------|
| `W-STR-STRIP-RUBY` | `strip` keeps Ruby's rules (NUL and ASCII whitespace), spelled out in Rust |
| `N-STR-STRIP-RUST` | `Rust::Str#strip` uses Rust `trim()` (Unicode whitespace, including NBSP; NUL is not stripped) |
| `W-STR-CAPITALIZE` | Ruby titlecases some characters (for example `ß`); Rust only uppercases |
| `N-RUST-INJECTED` | a `rust_item` or `rust_file` was injected; the compiler does not check its Rust |
| `N-EXEC-INJECTED` | a subprocess runs on every call; no sandbox |
| `N-BINDING` | which binding functions a server uses and what backs them |
| `N-OPENAPI` | an `openapi` declaration made one tool per operation, naming the file and the tools |
| `W-OPENAPI-AUTH` | operations need authentication but no `auth_setting:` was given, so requests go out without a key |
| `W-RUST-FN-MISSING` | a `rust_fn` names a function not found in its `rust_file` |
| `N-DEPRECATED-FEATURE` | declaring a `feature` the pinned rmcp deprecates (SEP-2577) is allowed; the emitted call is scoped with `#[allow(deprecated)]` |

```sh
RMCP_DSL_WARN=none make dsl-check                  # hide warnings
RMCP_DSL_WARN=W-STR-STRIP-RUBY make dsl-check      # show only these codes
```

An unknown code in `RMCP_DSL_WARN`, `RMCP_DSL_NOTICE`, `--warn` or `--notice` is an error.
