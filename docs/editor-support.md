# Editor support

_See also: [README](../README.md)._

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
