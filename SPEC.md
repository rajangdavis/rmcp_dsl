# Spec and test plan: Rust-shim library and string dispatch

Status: draft, 2026-10-03. Nothing here has been run; ruby and cargo live on the
owner's host. Context: SKETCH.md ("Tier 1 idea", "String shims").

## 1. Principle

The shim library (`lib/rust/`) is the specification. A method is supported iff

1. it has an entry in the shim catalog (section 2),
2. the Ruby implementation exists in `lib/rust/` and passes its examples, and
3. the compiler maps it, and the Rust it emits passes the *same* examples.

Anything else is a compile error naming `server.rb:LINE:COL`. The tests exist to
make (1)-(3) impossible to drift apart.

## 2. Catalog entry format

One entry per method form. Data, not code, so Ruby and Rust test generators read
the same file (`spec/shims/*.yml`, YAML chosen because it is in Ruby stdlib).

    - name: String#length
      kind: reimplemented          # plain_alias | reimplemented | refused
      ruby: "s.length"
      rust: "s.chars().count() as i32"
      types: { s: string, returns: i32 }
      notes: "Ruby counts characters; Rust len() counts bytes."
      examples:
        - { in: { s: "" },      out: 0 }
        - { in: { s: "abc" },   out: 3 }
        - { in: { s: "héllo" }, out: 5 }     # 6 bytes, 5 chars
        - { in: { s: "日本" },   out: 2 }

    - name: String#gsub(string, string)
      kind: reimplemented
      ruby: "s.gsub(a, b)"
      rust: "s.replace(a, b)"
      types: { s: string, a: string, b: string, returns: string }
      examples:
        - { in: { s: "aXa", a: "a", b: "b" }, out: "bXb" }
        - { in: { s: "a.a", a: ".", b: "!" }, out: "a!a" }   # literal, not regex
        - { in: { s: "x",   a: "",  b: "-" }, out: "-x-" }   # empty pattern: check

    - name: String#gsub(regex, string)
      kind: reimplemented
      ruby: "s.gsub(re, b)"
      rust: "RE.replace_all(&s, b)"        # RE = LazyLock<Regex>, see section 5
      deps: [ { crate: regex, version: "1" } ]
      examples:
        - { in: { s: "a1b22", re: "/\\d+/", b: "#" }, out: "a#b#" }
        - { in: { s: "a\nb",  re: "/^b/",   b: "X" }, out: "a\nX" }  # ^ is line anchor
        - { in: { s: "cost",  re: "/o/",     b: "$" }, out: "c$st" } # literal $

    - name: String#gsub(variable, _)
      kind: refused
      error: "gsub needs a string or regex literal; got LocalVariableReadNode"
      reject_examples: [ 'x.gsub(pat, "b")' ]

Rule: every entry has at least one empty-input, one non-ASCII, and one
boundary example unless `examples_waived: "reason"` is set (reviewable).

## 3. Test layers

Each layer answers one question and fails with a different message.

| # | Layer | Runs | Checks | Fails when |
|---|-------|------|--------|-----------|
| L1 | shim unit | Ruby (minitest) | each entry's `examples` against `lib/rust/` | the Ruby shim disagrees with its own catalog |
| L2 | transpile golden | Ruby | DSL snippet -> expected Rust text (`spec/golden/*.rs`) | emitted Rust changed |
| L3 | differential | cargo test | generated `tests/shims.rs` with the catalog examples as literals | emitted Rust behaves differently from the Ruby shim |
| L4 | compile | cargo check | emitted crate for every example server | emitted Rust does not compile |
| L5 | end to end | cargo run + script | spawn the binary, MCP `initialize` then `tools/call add`, assert reply | server does not speak MCP / wrong result |
| L6 | consistency | Ruby | shim catalog names == transpiler table names == `lib/rust/` methods | one list gained a method the others lack |
| L7 | refusal | Ruby | each `refused` entry and each rejected regex feature errors with `FILE:LINE:COL` and the documented message | something unsupported slips through |

L3 is the key one. L1 proves the Ruby shim; L3 proves the Rust matches it. The
expected values are written literally into the catalog, never computed at test
time, so neither side can quietly redefine "correct".

Ruby executes only the library's tests and the compiler. It never executes a
user's `server.rb` (the Prism rule from SKETCH.md stands).

## 4. Edge-case checklist (every string method)

empty string; single char; leading/trailing/repeated separators; non-ASCII
(`é`, `日本`, emoji, combining marks); CRLF vs LF; strings containing `{ } $ \ "`;
negative and zero integers for I32; `i32::MAX` boundary; for Option: nil in, nil out.

## 5. Regex spec

Allowed (Onigmo ∩ Rust `regex`): literals, classes `[...]`, `\d \w \s` and
negations, `. ? * + {m,n}`, lazy forms, groups, named groups `(?<n>...)`,
alternation, `\A \z \b`, flags `i m x`.

Rejected at compile time (message must name the feature and the line):
lookahead `(?=`, `(?!`; lookbehind `(?<=`, `(?<!`; backreferences `\1`, `\k<n>`
in the *pattern*; `\h`; `\G`; possessive quantifiers `++`; atomic groups `(?>`;
interpolation `#{}` inside the regex literal.

Translated:

| Ruby | Rust `regex` | test |
|------|-------------|------|
| `^` `$` (always line anchors) | prefix `(?m)` | `"a\nb".gsub(/^b/,"X")` |
| `/m` (dot matches newline) | `(?s)` | `"a\nb".gsub(/a.b/m,"X")` |
| `/i`, `/x` | `(?i)`, `(?x)` | one example each |
| replacement `\1`, `\k<n>` | `${1}`, `${n}` | `"ab".gsub(/(a)(b)/,'\2\1')` |
| literal `$` in replacement | `$$` | `"o".gsub(/o/,"$")` |

Each compiled regex is one `static RE_n: LazyLock<Regex>` per call site; a test
asserts two call sites produce two statics and none is built inside the tool fn.

## 6. Layout and runners (proposed)

    spec/shims/*.yml        catalog (source of truth)
    spec/golden/*.rs        L2 expected output
    spec/servers/*.rb       example servers (add, text tools) for L4/L5
    test/                   L1, L2, L6, L7 (minitest)
    tests/shims.rs          GENERATED from the catalog, never edited by hand
    Makefile targets        test-ruby (L1 L2 L6 L7), test-diff (L3), check-rust (L4), e2e (L5), check (all)

Host hooks (owner runs `raj hook add`; commands listed here, not yet created):

    raj hook add test-ruby --agent --tree projected -- make test-ruby
    raj hook add test-diff --agent --tree projected --timeout-ms 600000 -- make test-diff
    raj hook add check     --agent --tree projected --timeout-ms 900000 -- make check

## 7. v1 prototype acceptance

- Catalog entries: `downcase`, `upcase`, `length`, `strip`, `start_with?`,
  `include?`, `gsub(string,string)`, `gsub(regex,string)`, `sub` both forms.
- L1, L6, L7 green on the host; L3 green for the same entries.
- Both `gsub` forms compile into `examples/text.rb` and L4 passes.
- Differences found between Ruby and Rust are recorded in the catalog `notes`,
  not hidden by weakening an example.

## 8. Open questions

1. Encoding `nil`/`None` and lists in YAML examples (`out: null`? tagged forms?).
2. Whether L3 can batch all entries into one generated crate (faster) or needs
   one test per entry (clearer failures). Start batched, one `#[test]` each.
3. `strip`: choose Ruby-equal (ASCII whitespace + NUL) and emit a custom
   trim, or choose Rust `trim` and document the divergence. Needs a decision.
4. rmcp and `regex` versions are unpinned until the first host build.

## 9. Decisions (owner, 2026-10-03) and warnings

### 9.1 Example notation (open question 1, answered)
Only matters for how test examples are written in the YAML catalog. Proposal:
scalars as plain YAML; `Option<T>` as `null` (None) or the value; `Vec<T>` as a
YAML list; `Result` as `{ ok: v }` or `{ err: "msg" }`. Revisit if ambiguous.
Vector example (owner, 2026-10-03): a YAML list, floats written with a decimal
point so `f64` vs `i32` is visible in the example itself:

    - { in: { v: [1.0, 2.0, 3.0] }, out: 6.0 }       # Vec<f64>
    - { in: { v: [] },              out: 0.0 }       # empty vec

### 9.2 Batching and parallelism (open question 2: decided)
- **One generated crate** holds every catalog example, one `#[test]` per entry.
  Compile time dominates, so compile once.
- **cargo test runs tests in parallel by default**, so batching does not
  serialize execution. Failures still name the entry.
- Ruby side: minitest with `parallelize_me!` (L1, L2, L6, L7).
- Layers are independent, so `make check` may run L1/L2/L6/L7 (Ruby) alongside
  L3/L4 (cargo). Never run two cargo commands on one target dir at once (build
  lock); use a separate `CARGO_TARGET_DIR` if two must overlap.
- Sharding the catalog across several crates is deferred until measured compile
  time says it pays off.
- Optional later: `cargo nextest` for faster per-test parallel runs.

### 9.3 `strip`: each type behaves as its own language says (corrected)
Behaviour is set by the receiver's type. Warnings never change behaviour.

    native Ruby String#strip   behaves as Ruby: strips NUL, \t, \n, \v, \f, \r, space.
                               Emitted Rust reproduces that set explicitly, e.g.
                               s.trim_matches(|c| matches!(c, '\0'|'\t'|'\n'|'\x0b'|'\x0c'|'\r'|' '))
                               NOT plain trim(). (Rust's is_ascii_whitespace omits \v,
                               so it cannot be used.) Whether Ruby also strips a
                               leading NUL differs by version: UNVERIFIED, test on 4.0.7.
                               Emits WARNING W-STR-STRIP-RUBY: this Ruby strip compiles
                               to a custom trim; it is not Rust trim().
    Rust-compatible type       behaves as Rust trim(): strips Unicode whitespace
    (Rust::Str#strip/#trim)    (incl. U+00A0). Emits NOTICE N-STR-STRIP-RUST: this
                               strip uses Rust trim() semantics.

Catalog rule: an entry whose Ruby and Rust behaviour differ gets one entry per
receiver kind and a `notify:` block (code, level warning|notice, message). The
two entries have different `rust:` templates and different examples, e.g.
`" x"` strips to `" x"` for native Ruby but to `"x"` for Rust::Str.
Candidates besides strip: `length`, `split`, `reverse`, integer `/` and `%`.

    notify: { code: W-STR-STRIP-RUBY, level: warning, on: native_ruby, message: "..." }
    notify: { code: N-STR-STRIP-RUST, level: notice,  on: rust_type,   message: "..." }

Output format: `server.rb:LINE:COL: warning W-...: ...` or `... notice N-...: ...`.
Neither level ever fails the build.

### 9.4 Gates: environment variables only
The gate decides what is printed, never what is emitted. Generated Rust is
byte-identical with every setting.

    RMCP_DSL_WARN=all|none|CODE,CODE      warnings  (default: all)
    RMCP_DSL_NOTICE=all|none|CODE,CODE    notices   (default: all)

    CODE lists show only those codes. Unknown codes in the list are an error
    (a typo would otherwise hide nothing and look like it worked).
    The compile summary always counts what was hidden:
        "3 notifications hidden (W-STR-STRIP-RUBY x2, N-STR-STRIP-RUST x1)"

Removed from the earlier draft until asked for again: `--warn`/`--no-warn`
CLI flags, `--Werror`, and the inline `# rmcp:allow` comment.

### 9.5 Tests for notifications (layer L8)
| test | expect |
|------|--------|
| native `s.strip` | one W-STR-STRIP-RUBY at that line:col; Rust output uses the explicit char set |
| `Rust::Str` `.strip` | one N-STR-STRIP-RUST; Rust output is `.trim()` |
| `" x".strip` native | result `" x"` in both Ruby and generated Rust (L1 + L3) |
| same input via Rust::Str | result `"x"` |
| `RMCP_DSL_WARN=none` | no warning line; summary counts it; **emitted Rust identical** |
| `RMCP_DSL_NOTICE=none` | no notice line; emitted Rust identical |
| `RMCP_DSL_WARN=W-STR-STRIP-RUBY` | that warning shown |
| `RMCP_DSL_WARN=W-TYPO` | compile error naming the unknown code |
| every `notify:` code in the catalog | has a test above or an explicit waiver |

### 9.6 Update to the v1 acceptance list
Native Ruby `strip` keeps Ruby behaviour and emits a warning; `Rust::Str` strip is
Rust `trim()` and emits a notice; gates are environment variables only (9.3, 9.4).
Section 8 item 3 is closed by 9.3 and items 1 and 2 by 9.1 and 9.2.

## 10. Fast pre-validation: `rmcp_dsl --check` (owner ask, 2026-10-03)

Goal: validate the input before the slow compile-and-test run. Cheap because the
compiler already fails early with `FILE:LINE:COL`; `--check` is the same pipeline
stopped before it writes anything.

    rmcp_dsl --check server.rb      # no output files, no Rust toolchain needed
    rmcp_dsl --check --format json server.rb      # machine-readable, for editors/agents

Stages, cheapest first; each stage only runs if the previous passed:

| stage | what | needs |
|-------|------|-------|
| 0 | Ruby syntax (`Prism.parse_file` errors) | ruby |
| 1 | DSL shape: signature table, nesting, kwargs, names, duplicates, semver | ruby |
| 2 | body typing: locals, operator/type agreement, shim table membership, regex subset | ruby |
| 3 | notifications (warnings/notices, gated by env vars as in 9.4) | ruby |
| 4 | emit Rust and `cargo check` (separate command: `make check-rust`) | rustc |

`--check` covers stages 0-3 in milliseconds. Stage 4 stays in the existing
heavier layers (L4). Exit codes: 0 clean, 1 errors found, 2 bad usage.

Tests (layer L7 extended): every refusal fixture is run with `--check` and must
produce the same message as a full compile; `--check` must write no files.

Complexity cost, honestly: low. The one real design decision is **error recovery**.
v1 stops at the first error per tool (the compiler already works this way);
reporting several errors per file means the walker continues after a failure, so
it needs a "poisoned node" rule to avoid cascades. Defer until first-error-only
proves annoying.

Hook: `raj hook add check-fast --agent --tree projected --timeout-ms 30000 -- ruby bin/rmcp_dsl --check examples/add.rb`
(owner runs it; the heavy `check` hook stays separate).

## 11. Enforcing the DSL's structure in Ruby: Sorbet (spike result, 2026-10-03)

Spike (the `spike/` directory was removed 2026-10-04): `dsl.rbi`, `sample.rb`, `sorbet/config`, run with
`srb tc` on the host. Sorbet flagged exactly the five deliberate mistakes and
passed the valid tool:

    tool inside params          -> Method tool does not exist on ParamsScope
    field inside a tool         -> Method field does not exist on ToolScope
    missing description:        -> Missing required keyword argument description
    "AddParams" for a Symbol    -> Expected Symbol but found String
    unknown call                -> Method nonsense_call does not exist on ServerScope

Mechanism: `T.proc.bind(Scope)` on each DSL block types `self` inside it, so only
that scope's methods exist there.

### Division of labour (who enforces what)
| rule | enforced by |
|------|-------------|
| nesting (field only in params, etc.) | Sorbet |
| required keywords, argument types, unknown calls | Sorbet |
| symbol VALUES (`:i32` vs `:bogus`, CamelCase, keywords) | compiler `--check` (Sorbet has no literal types) |
| names refer to declared things (tool's `params:` exists) | compiler `--check` |
| allowed Ruby inside `body` (subset, shims, regex subset) | compiler `--check` |
| editor hover docs on `server` | solargraph + YARD stub (limited, see below) |

Solargraph spike result: with the stub saved and raj restarted, hover on the
top-level `server` call shows the YARD docs, but `@yieldself` is not honoured:
inside `params do` completion offers only Ruby constants and hover on `params`,
`tool` returns nothing. So solargraph gives docs on the outermost call only, not
structure. Solargraph is what raj's editor integration runs today.

### Plan
1. One source: the signature table (`SIG`) in the compiler. Generate
   `dsl.rbi` from it so Sorbet and the compiler cannot drift. A test fails if
   the committed `.rbi` differs from the generated one.
2. `make typecheck` runs `srb tc` over `examples/` and `spec/servers/`; a host
   hook `typecheck` runs it for agents. Order in the fast gate:
   `typecheck` (structure), then `rmcp_dsl --check` (values and bodies).
3. Negative fixtures: keep `sample.rb`-style files with expected error lines;
   a test asserts Sorbet reports exactly those. Covers regressions in the stub.
4. Open: can raj run Sorbet's language server (`srb tc --lsp`) in the editor
   instead of, or next to, solargraph? Unknown. Until then the CLI/hook is the
   enforcement point.
5. Open: `# typed:` level for generated servers; `true` worked in the spike.
6. The Sorbet annotations also keep a later bridge to ruby-lean open (it
   validates Sorbet-annotated Ruby), not a commitment.

Superseded: `lib/rmcp_dsl/dsl_stub.rb` and `spike/dsl_sample.rb` (YARD/solargraph
spike); proposed for deletion.

## 12. Status after the first working prototype (2026-10-04)

Where the plan in sections 1-11 stands. "Run" means the owner ran it on the host and the
output was checked; nothing else is claimed as passing.

| layer | what | status |
|-------|------|--------|
| L1 shim unit | `test/test_shims_string.rb`, 61 runs | built, run, passing |
| L2 transpile golden | none; the hand-written `golden/add` was removed 2026-10-04 (`make e2e` builds and calls the generated crate) | not built |
| L3 differential | `bin/gen_shim_tests` + `shimcheck`, 59 tests | built, run, passing |
| L4 compile | generated crates `cargo test`/`cargo run` | run for add, textkit; injected not yet |
| L5 end to end | `test/e2e_*.sh` over MCP stdio | run for add and textkit |
| L6 consistency | catalog names vs transpiler table | not built |
| L1/L3 bindings | `test/test_bindings.rb` (loader, refusals, Ruby references) and the `heck` examples in `bin/gen_shim_tests` | written 2026-10-04, not run yet |
| L7 refusal | each refusal fixture gives its message | `test/test_refusals.rb` over `test/refusals/*.rb` (9 fixtures); written 2026-10-04, not run yet |
| L8 notifications | codes and env gates | observed by hand; no automated test |

Decisions that changed or settled things written earlier in this file:
- 9.3 `strip`: native Ruby keeps Ruby behaviour and warns; the Rust-typed string follows
  `trim()` and notices. Implemented for the native side only (`Rust::Str` exists in
  `lib/rust/str.rb` for tests; the DSL has no way to declare a Rust-typed string yet).
- 9.4 gates: environment variables only, as decided. `--check` exists (section 10).
- Section 11: Sorbet is wired in (`make typecheck`); `rbi/dsl.rbi` is generated from `SIG`.
  Solargraph only gives docs on the top-level `server` call, so it is not an enforcement point.
- Section 5 regex rules: implemented in `lib/rmcp_dsl/regex_translate.rb` and checked against
  the real `regex` crate through the catalog. One rule is new: Ruby `\d \w \s` are ASCII-only,
  Rust's are Unicode, so the translator expands them to ASCII classes.
- `capitalize` is a catalog entry with a warning (`W-STR-CAPITALIZE`) because Ruby titlecases
  some characters that Rust only uppercases.
- Tier 2 injected Rust is implemented (`rust_crate`, `rust_item`, `rust_fn`, `rust(:name, ...)`)
  and raises `N-RUST-INJECTED`; its first proof is `examples/injected.rb` (`make e2e-injected`).

Open or next:
1. Run `make e2e-injected`; then build `fetchkit` (SKETCH.md), the first server that needs
   injected Rust for HTTP, with the loopback-blocking guard and a hermetic local fixture server.
2. Automate L6, L7 and L8; add golden comparison as a test.
3. A way to declare a Rust-typed string in the DSL, if the second notification is wanted.
4. Gem packaging, if the project is released; check that the name is free on rubygems.org.
