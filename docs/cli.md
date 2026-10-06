# The command line

The `rmcp_dsl` command and its subcommands.

_See also: [README](../README.md)._

| Command | Does |
|---------|------|
| `rmcp_dsl check FILE [--format json]` | Parse, type-check, report notifications; write nothing. `--format json` prints one document for editors and agents: `{ok, file, notes}` or `{ok: false, error: {file, line, col, message, suggestions}}`. Exit 1 on failure. Compile errors name the valid choices and suggest the nearest name when one looks like a typo (``unsupported method `upcas` ...; did you mean `upcase`?``); `suggestions` carries those names. `--types` (with `--format json`) adds `types`: `[{line, col, end_line, end_col, kind, type, name?}]` for every parameter, local and expression the compiler typed (lines and columns are 1-based, `end_col` exclusive, types read like Sorbet: `String`, `Integer (i64)`, `T.nilable(String)`), which is what an editor needs to show types in a body. |
| `rmcp_dsl lsp` | Run a language server on stdio for DSL files (see [Editor support](editor-support.md)). |
| `rmcp_dsl rbi FILE... [-o DIR]` | Write Sorbet signatures for the helpers the files declare (default `sorbet/rbi/rmcp_dsl/dsl_helpers.rbi`), so DSL files can be `# typed: true`. |
| `rmcp_dsl build FILE [-o DIR] [--release] [--emit-only]` | Write the crate (default `build/NAME`) and run `cargo build`. A rustc error inside generated code is printed at the DSL line that produced it. |
| `rmcp_dsl run FILE [-o DIR] [--release]` | Build, then start the server on stdio. |
| `rmcp_dsl init NAME [-o DIR] [--force] [--no-bindings]` | Scaffold a new project: write `DIR/NAME.rmcp.rb` (a minimal server that compiles) and a `DIR/bindings/` folder holding a `.gitkeep` so an empty folder survives version control. Refuses to overwrite an existing file without `--force`; `--no-bindings` skips the folder. Default `DIR` is `.`. |
| `rmcp_dsl skill [-o DIR]` | Write an agent skill folder (`rmcp-dsl/SKILL.md` plus references) that teaches the DSL. The reference pages are generated from the compiler, so they match the installed version. |
| `--warn SPEC`, `--notice SPEC` | Choose which notifications are printed (`all`, `none`, or codes). |
| `--version` | Print the version. |

The original form still works: `rmcp_dsl FILE -o DIR`, `--check`, `--dump-ir`.
