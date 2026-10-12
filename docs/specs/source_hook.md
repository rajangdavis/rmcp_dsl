# Spec: `file` — load any file, checked before the build (gap #33)

Status: built 2026-10-12 (`python_sig.rb`, `reader.rb` `add_any_file`, `body.rb` file calls, `emit.rb`
`files_runtime`, the LSP; tests `test_file_hook.rb`, `test_python_sig.rb`). The running server's re-check
compares the `def` header and TypedDict field lines the compiler read (comments dropped, whitespace collapsed),
so any change to them asks for a rebuild. Source:
`rmcp-for-blender/docs/rmcp-dsl-gaps.md` #33.

## What the owner decided (2026-10-11)

- "I wasn't thinking about a DSL for python, I just want to be able to load in python scripts or any files."
  So there is no `python_fn` and no `python(...)` call. A file is text the server reads.
- "I think disk, maybe entries is good here." The file is read from disk while the server runs, so an edit to
  it needs no rebuild, and `entries:` names the functions the server will call in it.
- "the more we can guarantee correctness before compilation, the better." Everything that can be checked
  from the file's text is checked by the compiler and the rmcp_dsl LSP, before cargo runs.
- Checking the file's own language (Python types, syntax) belongs to that language's server, which the raj
  editor runs, not the rmcp_dsl LSP ("worth delegating to the raj editor as to not overloading the dsl LSP
  server"). See WAVE-PLAN Track D.

## Problem

`blender.rmcp.rb` holds the path to `python/mcp_scripts.py` in a setting, reads it with `Json.read_text` on
every call, and names the function to run as a bare string (`run_module(..., "place", args)`). Nothing checks
at build time that the file exists or that `def place` is in it; a typo is an `AttributeError` inside
Blender. The Python that installs and invokes the module is itself built as escaped strings
(`blender.rmcp.rb:102-104`), because there is no way to load a second file as text.

## Surface

```ruby
server "blender", version: "0.2.0" do
  file "python/mcp_scripts.py", as: :scripts, env: "BLENDER_PYTHON",
       entries: %i[place look reveal material]
  file "python/runner.py", as: :runner

  tool :place, params: :PlaceParams, description: "..." do
    body do |name, x, y, z, relative|
      args = entry_args(:scripts, :place, name: name, x: x, y: y, z: z, relative: relative)
      run_module(file_text(:runner), file_text(:scripts), entry(:scripts, :place), args)
    end
  end
end
```

- `file PATH, as: :name` declares a file of any type. `env:` (optional) names a variable that replaces the
  path when the server starts. `entries:` (optional) lists the functions the server calls in it.
  Every check below is on by default, including the re-check on each read in the running server.
  `unchecked: %i[each_read]` turns one off; the names are `each_read` (the running server's re-check) and
  `args` (the `entry_args` comparison, for a file whose functions use annotations the scan cannot read).
  The entry and path checks cannot be turned off. Why a check is off goes in an ordinary comment on the
  line. Each opt-out prints notice `N-FILE-UNCHECKED` on the build, so it stays visible.

  ```ruby
  # A render loop reads this 60 times a second; the startup check is enough.
  file "python/hot_loop.py", as: :hot, entries: %i[tick], unchecked: %i[each_read]
  ```
- `file_text(:name)` in a body or helper is the file's text as a `String`, read from disk on each call, so
  an edited file is used without a rebuild.
- `entry(:name, :place)` is the string `"place"`, refused at build time unless `:place` is in that file's
  `entries:`. It is how a call names a function so the name is checked.
- `entry_args(:name, :place, key: value, ...)` is the JSON text of the arguments, written by the compiler
  from typed values (nil becomes `null`), and checked at build time against what `def place` declares. It
  replaces hand-built JSON strings, so a misspelt key or a wrong type is a build error in the DSL, not a
  `KeyError` or a bad value inside the callee.
- `rust_file` is unchanged. A `.rs` file is still copied into the crate and checked by rustc.

## Checks, in order

At build (`rmcp_dsl check`/`build`) and live in the rmcp_dsl LSP:

- Path rules as `rust_file`: relative to the declaring file, no `..`, no NUL, inside its folder after
  `File.realpath`, UTF-8, at most 1,000,000 bytes. The file must exist.
- Each `entries:` name must appear as a top-level `def NAME(` in the file (a text scan, as
  `warn_missing_module_fns` does for Rust, but an error instead of a warning). The language is taken from
  the extension; for `.py`, the `def` header must annotate every parameter and the return
  (`def place(args: PlaceArgs) -> Report:`), so the Python server can type-check the entry. A header the
  scan cannot read is refused rather than guessed.
- `entry(:f, :x)` must name a declared file and one of its entries; `file_text(:f)` a declared file.
- Arguments. `entry_args(:f, :x, ...)` is checked against the `def` the scan found, in one of two shapes:
  - **One TypedDict parameter** (`def place(args: PlaceArgs) -> Report:`, the Blender style): the scan
    reads `class PlaceArgs(TypedDict):` in the same file, one `name: type` per line. Every key passed must
    be a field, every field not marked `NotRequired[...]` must be passed, and each value's type must match.
  - **Plain parameters** (`def scale(name: str, factor: float) -> str:`): the keys must be the parameter
    names; a parameter with a default may be left out. The JSON is then an object of those names, and the
    caller unpacks it (`f(**args)`).
- Types match one to one: `str` ↔ `:string`, `int` ↔ `:i32`/`:i64`, `float` ↔ `:f64` (an integer is
  accepted), `bool` ↔ `:bool`, `list[str]`/`list[int]`/`list[float]` ↔ the list types, and `X | None`,
  `Optional[X]` or `NotRequired[X]` ↔ a nil-able value (a nil-able DSL value into a field that cannot be
  None is refused). Any other annotation (`dict`, `Any`, a nested TypedDict) is refused by name, so nothing
  crosses unchecked; typed records (`typed_record.md`) are where nested shapes would come later.
- An entry no `entry_args` call checks (a hand-built JSON string handed to it) gets warning
  `W-FILE-ARGS-UNCHECKED` on the call, so the unchecked path is visible.
- A file nothing reads, or an entry nothing names, is refused, like other unused declarations.
- The file joins `srv["inputs"]`, so a watcher rebuilds or re-checks when it changes.

When the server starts:

- The path is `env:`'s value if set, else the absolute path recorded at build. The server refuses to start
  when the file is missing or an entry's `def` is gone, naming the file and the entry (the same scan,
  emitted in Rust). An edit while the server runs is read on the next call, and each read re-checks the
  entry and its TypedDict or parameter list: a removed entry or a field that no longer matches fails the
  call first, naming it, before anything reaches the callee. With `unchecked: %i[each_read]`
  the check runs at startup only, and a later mismatch fails inside the callee (for Blender, a
  `KeyError` or `AttributeError` in the reply).

While editing (agent or human):

- The rmcp_dsl LSP watches each declared file (`workspace/didChangeWatchedFiles`, gap #9; raj forwards a
  save to every live server under the root), so saving a `.py` that drops or un-annotates an entry, or
  renames or retypes a field, puts a diagnostic on the `file` line and on every `entry_args` call it breaks. An agent reads it with
  `raj ctl lsp diagnostics blender.rmcp.rb --wait 10s` after saving the Python, without a build. The file's
  own syntax and types come from the Python server raj runs (WAVE-PLAN E10).
- The scan reads the file on disk, as the server will; an unsaved `.py` buffer is not seen until it is saved.

## Refusals

| Case | Message |
|---|---|
| not found, escapes, too big, not UTF-8 | the `rust_file` wording, with `file` for `rust_file` |
| duplicate | ``duplicate file `scripts` `` |
| entry missing | ```place` is listed in entries: but python/mcp_scripts.py has no top-level `def place(` `` |
| unannotated | ```def place(args)` in python/mcp_scripts.py needs a type on each parameter and a return type (`-> ...`)`` |
| unknown file | ``file_text(:script): no file has as: :script; did you mean :scripts?`` |
| unknown entry | ``entry(:scripts, :plcae): not in the entries of :scripts (place, look, ...)`` |
| unused | ``file `runner` is declared but nothing reads it`` |
| unknown key | ``entry_args(:scripts, :place): `nmae` is not a field of PlaceArgs (name, x, y, z, relative); did you mean `name`?`` |
| missing key | ``entry_args(:scripts, :place): PlaceArgs requires `name` (python/mcp_scripts.py:41)`` |
| wrong type | ``entry_args(:scripts, :place): `x` is `x: float | None` in PlaceArgs, got :string`` |
| nil into non-None | ``entry_args(:scripts, :place): `name` may be nil here, but PlaceArgs declares `name: str`; use `|| default` `` |
| uncheckable annotation | ``PlaceArgs.meta: `dict[str, Any]` cannot be checked; use str, int, float, bool, list[...] or X | None`` |

## Mapping onto the code

- `schema.rb`: a `file` row beside `rust_file` (`names: [:path]`, `kw: as:, env:, entries:, unchecked:`).
- `reader.rb`: `add_file` (today Rust only) splits into the shared path checks and the Rust copy; `file`
  records `{name, path, real, env, entries}` in a new `srv["files"]` and runs the entry scan.
- `body.rb`: `file_text(:x)`, `entry(:x, :y)` and `entry_args(:x, :y, ...)` beside `setting(...)`;
  `file_text` is fallible (the file can vanish while the server runs). `entry_args` writes its JSON with the
  existing JSON-value serialisation (`test_to_json.rb`).
- A small `python_sig.rb` reads a `def` header and a `TypedDict` class body into names and types. It is a
  line scan of a fixed subset, shared by the compiler, the LSP and the Rust re-check, and it refuses what it
  cannot read instead of guessing.
- `emit.rb`: a startup check beside the settings check, and a `file_text` function per file.
- LSP: diagnostics on the DSL line; go-to-definition from `entry(:scripts, :place)` to the `def` line;
  completion of entry names from the file; `lsp/sources.rb` serves an open buffer in place of disk.
- `rbi/dsl.rbi`: `file`, and `file_text`/`entry` in the body scopes.

## Tests

`test_file_hook.rb`: a good declaration; each refusal row; an entry on a multi-line `def` header; an open
buffer replacing disk; `env:` overriding the path; the cargo half starts the server with a missing entry
and expects the startup refusal, then removes an entry while it runs and expects the default re-check to
fail the call by name; with `unchecked: %i[each_read]` it expects the notice and no re-check. An unknown
name in `unchecked:` is refused. `test_lsp_*`: a watched `.py` change re-publishes the `file` line's diagnostic.
`test_python_sig.rb`: each shape (TypedDict, plain parameters, defaults, `NotRequired`, `X | None`,
`Optional[X]`, a multi-line header) and each refusal row for arguments; the emitted JSON round-trips through
`json.loads` into the declared keys.

## Settled (2026-10-11)

- Entries are checked: a top-level, fully annotated `def NAME(` for each name ("I think we can check
  entries").
- Arguments are checked too, field by field and type by type, through `entry_args` ("we should still do
  arg checks because throwing around python, ruby, and rust can create some weird debugging issues that
  we should try to avoid").
- Live checks: the LSP diagnostic covers editing, and the running server re-checks on each read ("maybe
  we can add an annotation/arg so live checks can be enforced or the agent can utilize the LSP
  diagnostics").
- All checks default on; an opt-out names the check (`unchecked: %i[...]`, the reason in a comment, "just
  do the simple thing... you can add code comments") and is reported on every build
  ("maybe we can default arg checks but do the same thing as the lsp for python, have a switch to turn it
  off in the config. I just want to ensure that if other people use this sort of DSL that we make it hard
  to do the wrong thing").
