# Spec: `use_dsl` — declarations from another file (gap #32)

Status: built 2026-10-12, as answered by the owner (the open questions below: `fragment do`, the same suffix,
nesting allowed, paths relative to the fragment, every declaration includable). Compiler: `reader.rb` `splice`,
`RmcpDsl::SOURCE_FILES`, `test_use_dsl.rb`; editor: `lsp/analysis.rb` (`Fragments`, `elsewhere`),
`lsp/server.rb` `publish_analysis`, `test_lsp_use_dsl.rb`. A cross-file duplicate adds " (first at FILE:LINE)"
(`reader.rb` `first_at`), and the `use_dsl` string completes the `*.rmcp.rb` files up to two folders below
(fragments first), both 2026-10-12. Differs from below: a fragment's root is found by scanning `use_dsl` lines
(directly or through other fragments), not by compiling candidates; helper-name completion across files is not
done. Source:
`rmcp-for-blender/docs/rmcp-dsl-gaps.md` #32.

## Problem

> `blender.rmcp.rb` is over a thousand lines: settings, a dozen helpers, 25 `params` blocks and 25 tools in
> one `server` block. The DSL has no include. ... a review cannot be scoped to one family, and two agents
> editing different tools still contend for one file.

`use_bindings` loads binding modules and `rust_file` copies Rust in; nothing loads DSL declarations.

## Surface

In the root file, inside `server`:

```ruby
server "blender", version: "0.2.0" do
  use_dsl "dsl/helpers.rmcp.rb"
  use_dsl "dsl/assets.rmcp.rb"
  transport :http, port: 8787
end
```

A fragment is a file whose single top-level call is `fragment do ... end` (mirrors "exactly one top-level
`server` call", `reader.rb` `read`):

```ruby
# dsl/assets.rmcp.rb
fragment do
  params :AssetSearch do
    field :query, :string
  end
  tool :search_assets, params: :AssetSearch, description: "Find assets" do
    body { |query| asset_label(query) }   # helper from dsl/helpers.rmcp.rb
  end
end
```

`fragment` takes no arguments. It exists so the Ruby/Sorbet side sees the same scope as `server` (see Editor
support); a bare list of declarations would be untyped. A fragment may hold what `server` holds except
`transport`: `params`, `output`, `tool`, `helper`, `prompt`, `resource`, `setting`, `feature`, `openapi`,
`rust_crate`, `rust_item`, `rust_fn`, `rust_file`, `use_bindings`, `cmd_fn`, `script_fn`, and `use_dsl`.

## Semantics

- The include is a splice at the `use_dsl` line. Declaration order, and so the order in `tools/list` and
  the order helpers are compiled in (`@helper_table`), is textual order across files.
- Everything lands in one server: tools see every helper, params, output and setting regardless of file. A
  helper may call only helpers declared earlier (the existing rule), so `helpers.rmcp.rb` is included first.
- Path: relative to the file that says `use_dsl`, no leading `/`, no `..`, no NUL, ends in `.rmcp.rb`, must
  stay inside the root file's folder after `File.realpath` (the `add_file` confinement), UTF-8, at most
  1,000,000 bytes (as `MAX_RS_BYTES`).
- `rust_file`, `openapi` paths inside a fragment resolve relative to that fragment; `use_bindings` still
  loads `bindings/` beside the root (`Bindings.dir_for`).
- Each included path is added to `srv["inputs"]`, so `--print-inputs`, the build watcher and the LSP
  re-analysis (`refresh_dependents`) see it.
- Duplicate names across files are refused, at the second declaration, in its own file.

Refusals (all `FILE:LINE:COL: message`, FILE the file that holds the node):

| Case | Message |
|---|---|
| `use_dsl` outside `server`/`fragment` | `use_dsl goes inside server or fragment` |
| missing file | `use_dsl file not found: dsl/x.rmcp.rb (looked in /abs/dir)` |
| bad path | `use_dsl path must be relative, inside the DSL file's folder, without .., and end in .rmcp.rb` |
| escapes root | `use_dsl file must stay inside /abs/root` |
| seen already, or a cycle | `dsl/a.rmcp.rb is already included (by blender.rmcp.rb:12)` |
| `transport` in fragment | `transport belongs in the file that says server` |
| not one `fragment` call | ``expected exactly one top-level `fragment` call`` |
| anything else at top | `a DSL fragment holds only declarations` |
| same name twice | ``tool `look` is declared twice (dsl/a.rmcp.rb:12 and blender.rmcp.rb:40)`` |
| build a fragment | `dsl/assets.rmcp.rb is a fragment; build the file that says use_dsl for it` |

(The in-file duplicate wording of `params_decl`, `helper_decl` etc. was not read for this spec; reuse it and
add the other file's `FILE:LINE`.)

## Mapping onto the code

- `reader.rb`: `read` checks `nodes.size == 1` and calls `call(nodes[0], :top)`; accept `server` or, for an
  included file, `fragment`. `each_child(blk, :server)` already walks a body; its `when` table gets
  `when :use_dsl then splice(n, p, srv)`, which parses the fragment (Prism, `Lsp::Sources[path]` first, like
  the constructor) and runs the same `each_child` over its block.
- File identity: `Diag#bad` (`rmcp_dsl.rb`) prints `@path` and `node.location`, and nodes carry no file.
  Keep the current file in `@path` while a fragment is processed (`with_file`). The deferred work (`pending`
  tools, `helper_nodes`, `prompt_nodes`, `resource_nodes`, the `@*_nodes` tables used in messages) must carry
  its file in the tuple and re-enter `with_file` when it runs. `Notify.add(@path, ...)` follows.
- IR: every declaration that has `"line"` gets `"file"` (absolute) beside it.
- `emit.rb`: `mapped(o, ranges, line, what)` and `source_map` emit `dsl_line` only; add `dsl_file` per range,
  and keep `"source"` as the root. `cargo_build.rb` prints `"#{map['source']}:#{hit['dsl_line']}"`; use
  `hit['dsl_file'] || map['source']`. The map format stays readable by old consumers.
- `lsp/analysis.rb`: `Diagnostic` gains `file`; `parse_errors` accepts any `FILE:` prefix, not only
  `@path`. `TypeNames::Collector.new(path)` entries gain a file so hover/inlay on a fragment's lines work.
- `lsp/server.rb`: publish per URI. A root analysis yields diagnostics for the root and for each fragment;
  remember which URIs it last published to and send `[]` to those no longer in error.

## Editor support

- Diagnostics: an error in `dsl/assets.rmcp.rb:12` appears on that file's line 12, whether the root or the
  fragment is open; fixing it clears it. Unreadable fragment: error at the `use_dsl` line in the root.
- Opening a fragment: find its root by (1) open documents whose analysis lists it in inputs, then (2) the
  `*.rmcp.rb` files in its folder and ancestors up to the workspace that contain a `use_dsl` naming it (the
  `named_by_a_sibling?` pattern in `reader.rb`). No root found: info diagnostic `no file says use_dsl for
  this fragment`.
- Hover: `use_dsl` keyword doc (`docs.rb`, add `use_dsl:` and `fragment:`). Go-to-definition on the path
  string opens the file; on a helper or params name it may now land in another file (`definition.rb`
  returns a Location with the fragment's URI). Completion offers `*.rmcp.rb` paths in the string. Outline
  shows a fragment's declarations; the root shows `use_dsl` entries.
- Types: `rbi/dsl.rbi` gets `def use_dsl(path); end` in `ServerScope` and a top-level
  `def fragment(&blk)` typed with the `ServerScope` block, so Sorbet and ruby-lsp check fragment bodies like
  server bodies. `Rbi.collect` takes helpers from the merged IR of roots, not from fragments alone.
- `docs/dsl.md`, `docs/editor-support.md` and `skill.rb` get the section; `schema.rb` gets `use_dsl` and
  `fragment` rows.

## Tests

- Golden: `examples/splitkit/` (root + two fragments) generates a `main.rs` byte-identical to the one-file
  `examples/splitkit_single.rmcp.rb`; only the map's `dsl_file` differs.
- `test/refusals/` cases for each row above (fixtures needing sibling files go under `test/fixtures/use_dsl/`,
  since `test_refusals.rb` runs one file in a temp dir).
- `test_inputs.rb`: fragments are inputs. `test_lsp_analysis.rb`: error in a fragment is reported with that
  file and line. `test_lsp_server.rb`: diagnostics published to the fragment URI, cleared on fix, refreshed
  by `didChangeWatchedFiles` and by an open unsaved fragment buffer (`Sources`).
- `test_cargo_build.rb`: a rustc error in a fragment tool prints `dsl/assets.rmcp.rb:LINE`.

## Open questions

1. Fragment shape: `fragment do ... end` (typed for Sorbet, symmetric) or bare top-level declarations?
2. File suffix: `.rmcp.rb` for both (the gap's example; the LSP treats `.rmcp.rb` as DSL) or a distinct
   `.rmcpx.rb` so tools can tell a fragment from a root by name?
3. Nesting: allow a fragment to `use_dsl` another (this spec does, with the cycle refusal), or root only?
4. Relative base for `rust_file`/`openapi` inside fragments: the fragment (this spec) or the root?
5. Should `prompt`, `resource`, `feature`, `openapi` be includable, or only the six the gap lists?
