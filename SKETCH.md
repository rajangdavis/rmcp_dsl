# Ruby DSL -> rmcp (Rust MCP SDK) codegen: sketch

Goal: describe an MCP server in Ruby, emit a Rust crate that uses `rmcp`.
Ruby is only the authoring/codegen layer; nothing Ruby runs at server runtime.

## Pipeline

    server.rb --(Prism parse + walk)--> IR (plain Ruby structs) --(emitters)--> Rust text

Keep the IR separate from the DSL so the DSL can change without touching emitters,
and so the IR can be dumped as JSON for debugging/golden tests.

## DSL (draft 1)

```ruby
require "rmcp_dsl"

RmcpDsl.server "calculator", version: "1.0.0" do
  instructions "Simple arithmetic."

  # shared parameter types -> `#[derive(Deserialize, JsonSchema)] struct`
  params :AddParams do
    field :a, :i32, doc: "left operand"
    field :b, :i32
  end

  tool :add, params: :AddParams, returns: :string, description: "Add two numbers" do
    rust "(a + b).to_string()"          # body is an escape hatch: raw Rust
  end

  tool :greet, description: "Say hello" do
    param :name, :string                # inline params -> generated GreetParams
    param :shout, :bool, optional: true
    rust <<~RS
      let s = format!("hello {name}");
      if shout.unwrap_or(false) { s.to_uppercase() } else { s }
    RS
  end

  prompt :review, description: "Code review" do
    arg :language, :string
    message :user, 'format!("Review {} code", args.language)'
  end

  resource "config://app", name: "app-config", mime: "application/json" do
    rust %q({"data": "value"})
  end

  transport :stdio                       # later: :streamable_http, port: 8080
end
```

Type vocabulary (symbol -> Rust): `:string String`, `:i32`, `:i64`, `:f64`, `:bool`,
`:json serde_json::Value`, `[:string]` Vec<String>, `optional: true` Option<T>,
`:SomeParams` refers to a declared `params`.

## IR (sketch)

    Server(name, version, instructions, tools[], prompts[], resources[], transport)
    Tool(name, description, params: ParamsRef|InlineFields, returns, body_rust)
    Params(name, fields[Field(name, type, optional, doc)])
    Prompt(name, description, args[], messages[])
    Resource(uri, name, mime, body_rust)

## Emitted layout

    out/
      Cargo.toml        rmcp + serde + schemars + tokio (+ anyhow)
      src/main.rs       tokio main, serve over chosen transport
      src/server.rs     struct, #[tool_router] impl, ServerHandler impl
      src/params.rs     derive structs

Ruby side: one ERB (or heredoc) template per file; start with plain string
building, move to ERB only if templates get big.

## Target Rust (what the emitter should produce for `add`)

Shape taken from the rmcp README, **not yet checked against a real compile**:

```rust
#[derive(Debug, Serialize, Deserialize, JsonSchema)]
struct AddParams { a: i32, b: i32 }

#[derive(Clone)]
struct Calculator;

#[tool_router(server_handler)]
impl Calculator {
    #[tool(description = "Add two numbers")]
    fn add(&self, Parameters(AddParams { a, b }): Parameters<AddParams>) -> String {
        (a + b).to_string()
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let service = Calculator.serve(rmcp::transport::stdio()).await?;
    service.waiting().await?;
    Ok(())
}
```

## Open questions

1. **rmcp API drift.** My README fetch was summarized by a small model and has
   suspicious bits (a `3.x` version, `ServerConfig`). Before writing emitters,
   pin an rmcp version and compile a hand-written `add` server; use that as the
   golden output. No ruby or cargo is installed in this container yet.
2. Raw-Rust bodies vs. a tiny expression DSL. Raw Rust is honest and cheap; the
   DSL then just removes boilerplate (schemas, routing, main). Leaning raw.
3. Async tools (`async fn`, `Result<_, McpError>` returns) - flag on `tool`?
4. Does the DSL cover server only, or client too?
5. Gem vs. single script. Start single script `rmcp_dsl.rb` + `examples/`.

## Next steps

1. Install ruby + rust (add `.tool-versions`), hand-write and compile the golden `add` server.
2. Write IR structs + the Prism front-end (see "Prism for the whole pipeline"), with a `--dump-ir` flag.
3. Emit `params.rs`/`server.rs`/`main.rs`/`Cargo.toml`; golden-test against step 1.
4. Add prompts, resources, transports.

## Make targets

Two layers: the Ruby generator, and the Rust it emits (built in `out/<name>/`).
Names are proposals.

    setup        bundle install; cargo fetch the golden crate
    gen          ruby bin/rmcp_dsl examples/NAME.rmcp.rb -o out/NAME   (NAME=calculator default)
    ir           same, --dump-ir: print the IR as JSON, emit nothing
    test         ruby unit tests (DSL -> IR, IR -> Rust strings)
    golden-diff  gen, then diff out/NAME against golden/NAME   (fails on drift)
    golden       regenerate golden/NAME from out/NAME           (writes; human only)
    lint         rubocop on the generator
    fmt          cargo fmt on out/NAME (rustfmt makes emitted diffs stable)
    rust-check   cargo check in out/NAME   (the real test that the output compiles)
    rust-clippy  cargo clippy on out/NAME  (optional, slower)
    check        test + gen + fmt + golden-diff + rust-check   (the one gate)
    clean        rm -rf out

`rust-check` is the target that matters: golden text can match and still not
compile against rmcp.

## Hooks that satisfy them

Hooks are stored by `raj hook add` and run by name. Authoring is local-only
(a TCP editor refuses `add`), so these are for you to run on your machine.
An agent may only run a hook added with `--agent`; `run` crosses TCP.

    raj hook add check      --agent --tree projected --timeout-ms 600000 -- make check
    raj hook add test       --agent --tree projected --timeout-ms 120000 -- make test
    raj hook add rust-check --agent --tree projected --timeout-ms 600000 --cooldown-ms 5000 \
        --param NAME=enum(calculator) -- make rust-check
    raj hook add gen        --agent --tree projected --may-write -- make gen
    raj hook add golden     --may-write --tree workspace -- make golden

- `--tree projected`: runs against the buffers incl. proposed text, so I can
  verify my own proposals before you accept (same as the `check` hook the
  raj project itself uses).
- `golden` has no `--agent`: rewriting the expected output is a human decision.
- `NAME` as a declared param keeps the example list closed instead of letting an
  agent pass arbitrary strings into make.
- `gen`/`check` write `out/`. Unsure whether a projected run needs
  `--may-write` for that, or whether `out/` should go to a temp dir instead.

## Hook questions

1. Are `check`/`test` the only hooks you want agents to run, or also `rust-check`?
2. `may-write` on projected tree: confirm semantics before relying on it.
3. Keep `out/` in the workspace, or generate into a temp dir (cleaner for hooks)?

## Toolchains (reported by owner, host machine, 2026-10-03)

    rustc 1.99.0 (b940084d7 2026-09-28)
    ruby 4.0.7 (2026-09-15) +PRISM [x86_64-darwin24]

Pin both in `.tool-versions` (`ruby 4.0.7`, `rust 1.99.0`) and set
`rust-version = "1.99"` in the emitted Cargo.toml. cargo version not reported;
assume it ships with rustc 1.99.

These live on the host, not in my container. So I cannot run them directly:
`raj ctl exec` is refused over TCP. The path is **hooks**: `raj hook run` crosses
the boundary and executes on the host. That is the real reason to define the
`check`/`test`/`rust-check` hooks above; without them I can write code but never
see it compile.

## Direction: Ruby compiles to the Rust MCP server

Restating the intent so the sketch matches it: the Ruby DSL is a **compiler
front-end**; its output is the Rust MCP server crate. Ruby is authoring-time
only. Possible further layer: prompt -> Ruby DSL.

    prompt / intent  --(LLM)-->  server.rb (DSL)  --(compiler)-->  Rust crate  --(cargo)-->  binary
        L0                          L1                               L2

Properties worth keeping:
- Each arrow is independently runnable and checkable. L1->L2 is deterministic
  and golden-testable. L0->L1 is the only fuzzy step, and its output (a short
  Ruby file) is small enough for a human to read and diff.
- The DSL is the review surface. A person approves ~30 lines of Ruby, not a
  crate of generated Rust.
- Bodies stay raw Rust (`rust "..."`) so L1 never has to be Turing-complete.

## Folders vs code per layer (to test, not decide)

The owner mentioned Jake Van Clief's idea of folders for agent use. It is
"Interpretable Context Methodology: Folder Structure as Agentic Architecture"
(Van Clief & McDermott, arXiv 2603.16021); see the ICM section below. This
question is the generic version of it:

Question: at each layer, is the unit of definition a **code file** or a
**folder of small files** that an agent can navigate?

Scenario A, code at every layer (current sketch):

    server.rb                      one DSL file
    out/calculator/src/*.rs        generated

Scenario B, folder as the source of truth, DSL optional:

    calculator/
      server.toml                  name, version, transport
      tools/add/
        tool.md                    description (this IS the tool description)
        params.json                fields, types
        body.rs                    raw Rust body
      prompts/review/...
      resources/...

  Compiler walks the folder and emits the same Rust crate. An agent edits one
  small file per concern, and the file path is the address.

Scenario C, hybrid: folder layout, with `tool.rb` per tool holding the DSL
fragment. Folder gives structure, Ruby gives expressiveness.

Cheap way to compare: both A and B feed the same IR. The IR and the Rust emitters
are shared, so the experiment is only "two loaders", and golden output must be
byte-identical for the same calculator server.

## Updated next steps

1. You run the hook setup; I get `check` and `rust-check` on the host.
2. Hand-write and compile the golden `add` server with rustc 1.99 (pin rmcp).
3. IR + Loader A (DSL). Emit. Golden-diff against step 2.
4. Loader B (folder). Same golden must pass.
5. Then decide whether L0 (prompt -> DSL/folder) targets A or B, based on which
   one the model writes more reliably.

## ICM (Van Clief & McDermott, arXiv 2603.16021)

Source: an HTML rendering of the paper, read through a summarizing fetch, so
the layout below is secondhand. Verify against the paper before copying it.

Idea: replace multi-agent orchestration with filesystem structure. One agent
walks numbered stage folders; each stage's `CONTEXT.md` says what to load, what
to do, and what to write. Five context layers:

    L0  CLAUDE.md                     which workspace this is, where things are
    L1  CONTEXT.md (root)             which stage handles which task
    L2  stages/NN_x/CONTEXT.md        stage contract: Inputs / Process / Outputs
    L3  references/, _config/         stable material, set up once
    L4  stages/NN_x/output/           per-run artifacts, input to the next stage

    workspace/
      CLAUDE.md
      CONTEXT.md
      stages/
        01_research/  CONTEXT.md  references/  output/
        02_script/    CONTEXT.md  references/  output/
      _config/

Claims: each stage loads only 2-8k tokens instead of a 30-50k monolithic
prompt; a human reviews/edits `output/` between stages; reported by the authors
from two production workspaces and 33 practitioners (not independently tested).

### Two different uses of it here (do not conflate)

1. **ICM as the workflow for building a server (prompt -> DSL -> Rust).**
   This is the L0->L1->L2 pipeline above, run as stages:

       stages/
         01_spec/     CONTEXT.md  output/spec.md          prompt -> plain-language server spec
         02_dsl/      CONTEXT.md  output/server.rb        spec -> DSL (references/: dsl.md, examples)
         03_compile/  CONTEXT.md  output/crate/           run compiler (deterministic, no LLM)
         04_verify/   CONTEXT.md  output/report.md        cargo check/test results

   Stage 03 and 04 are hooks, not agent judgment. The human review boundary
   between stages maps onto raj proposals: accept `server.rb` before 03 runs.
   `references/dsl.md` is where the DSL gets taught to the model once, so a
   prompt does not need to restate it.

2. **Folders as the server definition (Scenario B above).**
   That is a source format for the compiler, not an agent workflow. It borrows
   ICM's "path is the address, one small file per concern" but is not ICM itself.

They compose: ICM stage 02 can write either `server.rb` (Scenario A) or a
`calculator/` folder (Scenario B). The experiment in "Folders vs code" decides
which the model writes more reliably.

### Consequences for the make/hook plan

- `stages/NN` order suggests hook names mirroring stages (`compile`, `verify`),
  with `check` still the single gate.
- ICM keeps `output/` in the workspace as an audit trail. That answers the open
  question: keep `out/` in the workspace, not a temp dir.

## Bodies in Ruby instead of raw Rust

Yes, possible. Three ways, in rising cost. Target: the `body` of a tool/prompt/
resource is written in Ruby and the compiler emits Rust for it.

    tool :greet, description: "Say hello" do
      param :name,  :string
      param :shout, :bool, optional: true
      body do |name, shout|
        s = "hello #{name}"
        shout ? s.upcase : s
      end
    end

emits roughly:

    let s = format!("hello {}", name);
    if shout.unwrap_or(false) { s.to_uppercase() } else { s }

### Option 1: recording proxies (no parsing)

Block args are `Expr` objects whose operators build an IR tree (`a + b` returns
`Add(a, b)`). Pure Ruby, no source access. But `if`, `&&`, `||`, string
interpolation and assignment cannot be overloaded, so it needs `iff(c){}`,
`and_(a, b)`, `fmt("hello %s", name)`. Safe but it stops looking like Ruby.

### Option 2: transpile a Ruby subset with Prism (recommended to try first)

Ruby 4.0.7 ships Prism. Take the block's `source_location`, parse the file,
find the block node, walk the AST, emit Rust. Real Ruby syntax, real Ruby
syntax errors, no proxies. Needs the block to live in a file (not `eval`/irb).

Supported subset, v1 (anything else is a compile error naming the line):

    literals          ints, floats, strings, true/false, nil -> None
    interpolation     "x #{y}"            -> format!("x {}", y)
    locals            s = ...             -> let s = ...;
    operators         + - * / % == != < <= > >= && || !
    conditionals      if/elsif/else/unless, ternary  (as expressions)
    last expression   is the return value
    method table      upcase->to_uppercase, to_s->to_string, length->len(), ...
    optional params   x.nil?, x || default -> unwrap_or

Types: params are declared, so locals are inferred forward from them. If
inference cannot decide, the compiler asks for an annotation
(`s = "hi" #: String`), it never guesses.

### Option 3: a real Ruby -> Rust compiler
Full inference, blocks/closures, arrays, hashes. That is a language
implementation. Out of scope; Option 2 can grow toward it only if needed.

### The caveat that must be stated up front
This is **Ruby syntax with Rust semantics**, not Ruby. Cases where they differ:

    -7 / 2        Ruby -4 (floor)   Rust -3 (truncate)
    2**40 on i32  Ruby bignum       Rust overflow (panic in debug)
    nil           Ruby any-type     Rust Option<T>, must be typed
    "a" + "b"     Ruby new string   Rust String + &str, needs borrow
    mutation      Ruby everywhere   Rust needs `let mut` and ownership

Rule: the transpiler targets Rust semantics and documents each difference; where
it cannot be exact (e.g. `/` on possibly-negative ints) it either emits a Rust
call with the Ruby behavior (`div_euclid`) or refuses. A test suite should run
each snippet in Ruby *and* the emitted Rust and compare, on a small corpus.

### Effects
Pure expressions cover `add`/`greet`. Tools that do I/O (HTTP, files, DB) are
the real reason `rust "..."` exists. Plan: keep `rust "..."` as the escape hatch,
and add named intrinsics later (`http.get(url)`) that map to chosen crates,
rather than letting arbitrary Ruby calls through.

### Why it fits the rest of the sketch
- It makes `server.rb` self-contained: the human reviews one Ruby file, not
  Ruby plus embedded Rust strings.
- Testable hypothesis for the prompt layer: a model may write correct Ruby
  bodies more reliably than Rust bodies. Measure it with the same calculator
  spec, once with `body do` and once with `rust "..."`.
- Compatible with folder Scenario B: `tools/add/body.rb` instead of `body.rs`.

### Suggested order
1. Golden `add` with `rust "..."` (unchanged).
2. Prism walker for: literals, locals, operators, if/ternary, interpolation.
3. Same golden must come out of `body do |a, b| (a + b).to_s end`.
4. Add the method table and optional params; then the Ruby-vs-Rust semantic tests.

## Prism for the whole pipeline (decision, 2026-10-03)

Owner decision: use Prism for the entire Ruby -> Rust path, not only for bodies.
That supersedes `instance_eval` (the pipeline line and next-steps above are
updated). `server.rb` is never executed; it is parsed and read as data.

    server.rb --Prism.parse--> AST --walker--> IR --emitters--> Rust crate
    body blocks (same file) ------^   same walker, same errors

### What changes
- **One front-end.** The DSL calls (`tool`, `param`, `prompt`) and the bodies are
  both AST nodes. Same file:line:col in every error, e.g.
  `server.rb:14:7: unsupported: while loop in tool body`.
- **`server.rb` is valid Ruby, but only a subset is meaningful.** Editors, rubocop
  and syntax highlighting keep working. The compiler defines the subset.
- **No code runs at compile time.** Safe to compile a model-written `server.rb`:
  no `system`, no `require`, no file access. This matters for the prompt layer.
- **Arguments must be statically known.** Symbols, strings, ints, bools,
  arrays/hashes of those. `tool :"#{x}_get"` or a `%w[a b].each { tool ... }`
  loop is rejected, unless we later add explicit macros (`each_of`).
- **Folder loader (Scenario B) reuses it.** `tools/add/body.rb` goes through the
  identical body walker; only the loader differs.

### Walker shape
    Compiler::Parse   Prism.parse_file -> Prism::ProgramNode (fail on errors)
    Compiler::Dsl     visits CallNode on the top-level block: server/params/tool/
                      prompt/resource/transport -> IR declarations
    Compiler::Body    visits a block's StatementsNode -> Rust expr IR + types
    Compiler::Emit    IR -> Rust text (no Prism involved from here on)

Prism::Visitor (or `Prism::Compiler`) dispatches on node class; unknown node
class = error naming the node (`WhileNode`, `DefNode`, ...). A deny-by-default
walker is the safety property: new Ruby syntax cannot sneak into output.

### Consequences for earlier choices
- The recording-proxy option (Option 1) is dropped.
- Source locations come free, so generated Rust can carry `// server.rb:14`
  comments and a `#line`-style map for cargo errors.
- `rust "..."` stays as an escape hatch; its string is opaque to the walker and
  not type-checked. Mark it in the IR so a report can list "N unchecked bodies".

### Open points
1. Prism API stability across Ruby versions: pin ruby 4.0.7 and the `prism` gem
   version in the Gemfile, so the node classes are fixed.
   
   Yes absolutely.
   
2. Hash-style kwargs (`tool :add, params: :AddParams`) arrive as
   KeywordHashNode; fine, but shorthand `foo:` and `**opts` are rejected.
   
   
   we should really be mindful of how we process these sort of things,
   it might make it brutal to parse in rust unless what you are is something in Ruby that makes this bearable.
   
   
3. Heredocs for `rust <<~RS` need Prism's string node handling;

    Agreed


4. Is it OK that `server.rb` cannot use arbitrary Ruby (constants, helper
   methods) to avoid repetition? Reuse would come from `params :X` instead.

We should definitely have some rules around what is valid ruby grammar to the extent that we can also define some sort of LSP server or some grammar checker ideally using some Ruby typehints

### Reply to the open-point comments (Claude, 2026-10-03)

1. **Pinning:** agreed, no further work. Gemfile pins `prism`; `.tool-versions` pins ruby.
2. **kwargs "brutal to parse in rust":** I read this as a worry about hash/kwarg
   handling cost. The parsing happens in Ruby (Prism), not Rust; Rust only
   receives already-resolved emitted code, so the Rust side never sees kwargs.
   The worry is still right for the Ruby side, so: every DSL call gets a fixed
   **signature table** (allowed keys, value types, required/optional), and the
   walker only accepts exactly that. No `**opts`, no shorthand, no free-form
   hashes. If you meant the compiler itself being written in Rust, say so; that
   is a different design.
3. **Heredocs:** agreed; test `rust <<~RS` first when the walker exists.
4. **Grammar rules + LSP/type hints:** agreed, and it combines with 2. Proposal:
   make the signature table the single source of truth and generate from it:

       dsl_schema.rb  (one declarative table of calls, keys, types, nesting)
         |-- walker validation + error messages
         |-- sig/rmcp_dsl.rbs  RBS signatures for tool/param/prompt/...
         `-- docs / completion data for an editor

   RBS can type a block's `self`, so `tool :add do ... end` gets
   `{ () [self: ToolBuilder] -> void }` and `param`/`body` resolve inside it.
   Then Steep (RBS type checker) and ruby-lsp can check and complete `server.rb`
   with no custom LSP. A custom LSP is only needed for what RBS cannot say
   (e.g. "`body` block args must match declared `param`s"), and that check
   can live in the compiler's `--check` mode first.
   Type hints for bodies: RBS inline comments (`#: (String, bool?) -> String`)
   are the likely form. Not verified against ruby 4.0.7 / current Steep; test
   before committing to it.

   Validity rules to write down (the "allowed Ruby" spec): permitted node
   classes; the DSL call table; the body subset from the earlier section; no
   constants, no `def`, no `require`, no loops at DSL level.

New order of work: signature table -> walker -> RBS generation -> `--check`.

## Direction: Ruby-first logic, small Rust escape hatches (owner, 2026-10-03)

Owner: model tools in pure Ruby as much as possible and have the compiler emit
the right Rust. Not dogmatic about Ruby/Rust only. Escape hatches should be
small. Preferred form: raw Rust injected into the final server code. Open to
exploring "injected evaluated rust code" (meaning to be pinned down, see below).

### Three tiers

1. **Ruby subset, transpiled (the default).** Real Ruby names map to Rust std
   through a curated shim table, so file/IO-style tools stay in Ruby:

       File.read(p)        -> std::fs::read_to_string(p)  (error -> McpError)
       File.exist?(p)      -> std::path::Path::new(p).exists()
       Dir.children(p)     -> std::fs::read_dir(p) ... collected, sorted
       str.split / strip / start_with? / include? / lines
       arr.map / select / each / join / sort / first
       hash literal / h[k] -> HashMap / BTreeMap
       nil / x.nil?        -> Option;  raise "msg" -> Err(McpError)
   Rule: a Ruby name is supported only if the table maps it with Ruby-equal
   behaviour or refuses. Each new shim entry gets a Ruby-vs-Rust test.

2. **Injected Rust, declared and typed (the escape hatch).** Raw Rust goes into
   the output crate verbatim, but it declares a signature so Ruby bodies can call
   it and the walker still type-checks the boundary:

       rust_fn :slugify, args: { s: :string }, returns: :string, code: <<~RS
         s.to_lowercase().replace(' ', "-")
       RS
       rust_use "regex::Regex"
       rust_crate "regex", "1"          # -> Cargo.toml dependency

   Variants: inline `rust "expr"` inside a body (opaque, untyped, smallest);
   top-level `rust_item "fn ... {}"` for helpers. The compile report lists every
   injection, so reviewers see exactly how much of a server is not Ruby.

3. **Evaluated Rust (exploratory).** Candidate meanings, pick one to try:
   a. *Checked at compile time:* the compiler builds each snippet in a scratch
      crate with its declared signature (`cargo check`), so errors point at
      `server.rb:LINE`, not at generated code.
   b. *Verified by examples:* `examples: [[["Hello World"], "hello-world"]]` on a
      `rust_fn` emits `#[test]`s; a hook runs `cargo test`. Same idea for Ruby
      bodies: examples become tests of the generated Rust.
   c. *Ruby as oracle:* because bodies are valid Ruby, an explicit `--oracle`
      mode could run the Ruby body on the examples to produce the expected
      values, then compare with the generated Rust. This is the one place Ruby
      would be executed, so it must be opt-in and only for trusted files,
      keeping the default "never execute server.rb" rule intact.
   d. *Rust evaluated at Ruby compile time and spliced in (const-eval style):*
      possible but I see no use yet.

### Effect on the ladder
The target server is now the small text-tools server (see "Target server: textkit"
below; the ICM-workspace and trip-planner ideas were dropped by the owner). Tier 1
should cover string and array logic; Tier 2 is expected to stay unused for it. The measure of success is the count of injected lines
per server, tracked in the compile report.

### Owner decisions on the three tiers (2026-10-03)
- **Tier 2 (injected, typed Rust): accepted** as written.
- **Tier 3 (evaluated Rust): dropped.** Owner had (d) in mind, then agreed it is
  not needed. The (a)-(d) text above is superseded; keep only as history.
- **Tier 1: explore Ruby objects that simulate Rust builtins**, instead of a
  one-way table of Ruby names -> Rust. Open to playing with it.

### Tier 1 idea: an executable Rust-builtins shim library in Ruby

`lib/rust/` holds plain Ruby classes (or refinements) whose API is the Rust API
by name and by behaviour:

    Rust::Option  some/none, map, unwrap_or, is_some?, ok_or
    Rust::Result  ok/err, map, map_err, unwrap_or, ?-style early return
    Rust::Vec     push, len, iter/map/filter/collect, join, sort
    Rust::Str     trim, to_lowercase, to_uppercase, replace, split, lines,
                  starts_with?, contains, parse_i32
    Rust::Fs      read_to_string(path), read_dir(path), exists?(path)
    Rust::I32     wrapping/checked arithmetic, truncating `/` and `%`

Two shapes to compare:
- **Wrapper classes** (`Rust::Str.new("a")`): explicit, easy to type-infer from
  constructors, but literals need wrapping and the code stops looking like Ruby.
- **Refinements** (`using Rust::StrExt` adds `trim`, `to_lowercase` to String;
  `using Rust::I32Ext` makes Integer `/` truncate): values stay ordinary Ruby
  objects, bodies read naturally, and refinements are lexical so nothing leaks.
  The compiler never runs them; they exist for tests and docs.

What this buys:
1. **Rust semantics by construction.** The Ruby-floor vs Rust-truncate mismatch
   becomes a documented behaviour of the shim, not a silent gap.
2. **The shim library is the spec of the transpiler's method table.** A method
   is supported iff it exists in `lib/rust/` AND the compiler maps it. A check
   fails the build if the two lists differ.
3. **Differential tests for free.** Each shim method has Ruby examples; the same
   examples are emitted as Rust tests and run by a hook (`cargo test`). Ruby
   runs only the library's own tests, never a user's `server.rb`.
4. **Names map 1:1** (`to_lowercase` -> `.to_lowercase()`), so the transpiler
   stops needing per-method rewrite rules for most of the table.

Cost: Ruby written against these names is "Rust-flavored Ruby", not idiomatic
Ruby (`s.to_lowercase`, not `s.downcase`). A thin alias layer (`downcase` ->
`to_lowercase`) can be added later if idiomatic Ruby matters.

Suggested first prototype: `Rust::Str` + `Rust::Option` + `Rust::I32` as
refinements, enough to write the level-2 text tools (`slug`, `word_count`,
`title_case`) and run their shim tests on the host.

### String shims: aliases and type-directed dispatch (owner idea, 2026-10-03)

Direction: idiomatic Ruby names are the default, Rust names exist as aliases.
Each shim entry is one of three kinds, and each has a Ruby-vs-Rust example test:

    plain alias    upcase/downcase, start_with?, include?, empty?  -> same Rust op
    reimplemented  Ruby name, compiler emits Rust matching the shim's Ruby
                   behaviour: length -> .chars().count() (Ruby counts chars,
                   Rust len() counts bytes), reverse -> chars().rev().collect(),
                   strip documented against Rust trim (ASCII vs Unicode space)
    refused        forms with no safe mapping

**Type-directed `gsub`/`sub`/`split`/`match?`** (owner idea): Prism tells the
compiler the literal kind of the argument statically, so it can choose:

    s.gsub("a", "b")    StringNode            -> s.replace("a", "b")
    s.sub("a", "b")     StringNode            -> s.replacen("a", "b", 1)
    s.gsub(/a+/, "b")   RegularExpressionNode -> RE_1.replace_all(&s, "b")
    s.sub(/a+/, "b")                          -> RE_1.replace(&s, "b")

For the regex case the compiler also: adds `regex = "1"` to Cargo.toml (same
dependency set that tier-2 `rust_crate` feeds), and emits one compiled regex per
site, not per call:
`static RE_1: LazyLock<Regex> = LazyLock::new(|| Regex::new("a+").unwrap());`
(LazyLock is std, stable on rustc 1.99.)

Guardrails, because this is where Ruby and Rust disagree:
- Dispatch only on a **literal** (or a local the walker typed as string/regex).
  An untyped variable is a compile error, not a guess.
- Ruby regexes are Onigmo, Rust's `regex` crate is not. Reject at compile time,
  with `server.rb:LINE:COL`, lookahead/lookbehind, backreferences, `\h`, `\G`,
  possessive quantifiers, and anything the crate lacks. Document the allowed
  subset.
- Translate known differences: Ruby `^`/`$` always match at line boundaries, so
  emit `(?m)`; Ruby `/m` means dot-matches-newline, so emit `(?s)`; `\A`/`\z`
  map across; `/i` and `/x` map directly.
- Replacement strings differ: Ruby `\1`, `\k<name>` become Rust `${1}`,
  `${name}`, and a literal `$` must become `$$`.
- Block form (`gsub(/x/) { |m| ... }`) is out of v1; it would map to a closure.
- Same dispatch pattern extends later to `split(" ")` vs `split(/\s+/)`, `scan`,
  `match?`, `=~`, `start_with?(regex)`.

## Target server: textkit (owner, 2026-10-03; replaces trip planner and ICM ideas)

Owner asked for something dramatically scaled down. Smallest useful target that
still exercises the compiler: a few pure text tools. No network, no files, no
secrets, no auth. Everything is string logic, which is exactly what the shim
catalog (SPEC.md) covers.

### Tools (v1)
    add(a, b)             -> a + b as text                 (already exists)
    slug(text)            -> "  Hello, World! " => "hello-world"
    word_count(text)      -> number of words
    title_case(text)      -> "the quick fox" => "The Quick Fox"
    redact_digits(text)   -> every digit replaced by "#"

### What each one exercises
| tool | shims used | why it is in |
|------|-----------|--------------|
| add | i32 arithmetic | the existing golden |
| slug | strip, downcase, gsub(regex), gsub(string) | the `strip` notifications and both gsub forms |
| word_count | split, length | `split` and `length` differences (SPEC.md section 4 edge cases) |
| title_case | split, map/join, upcase on first char | blocks/closures in bodies (the first feature past `add`) |
| redact_digits | gsub(regex) | simplest regex path and the regex dependency being added to Cargo.toml |

### Success criteria
1. All five tools written in Ruby only, with zero injected Rust (tier 2 unused).
2. `--check` passes; the generated crate compiles; `tools/call` for each tool returns the
   expected text in an end-to-end test.
3. Edge cases pass in both languages: empty string, non-ASCII, leading/trailing
   separators, `{ } $`.
4. The expected notifications fire for `strip` and nothing else is noisy.

### Not in scope
HTTP, JSON, environment variables, files, OAuth, resources, prompts, state.
Those wait until this is green.

### Open questions
1. Is `title_case` too much for v1? It is the only tool needing a block
   (`map { ... }`). It can wait if blocks are not ready.
2. Are these the right tools, or does the owner want others of the same size?

## Roadmap decision (owner, 2026-10-03): textkit first, then fetchkit

1. **textkit** (section above) is the proof of concept. Written as "testkit" in the
   owner's message; taken to mean textkit.
2. **fetchkit** comes after textkit is green: basic curl-style fetching and scraping.

### fetchkit (draft, not started)
Tools, v1 (GET and HEAD only; owner decision 2026-10-03: POST comes in a later stage):

    fetch(url)              -> status, content_type, body (size-capped)
    select(url, css, attr?) -> list of matching elements' text, or attribute values
                               (links = select(url, "a", "href"); title = select(url, "title"))

Likely crates (injected until shims exist): an HTTP client such as `ureq` and an
HTML parser such as `scraper`. Verify choices when starting.

Ruby-side shim names follow Ruby's own libraries where sensible (`Net::HTTP.get`,
Nokogiri-style `doc.css("a")`), mapped to those crates. Parser leniency differs
between Nokogiri and Rust parsers, so those shims get notifications like `strip`.

Safety is part of v1, not later:
- Block loopback, private ranges and link-local/metadata addresses by default.
  Re-check after each redirect, not only for the first URL.
- Tool results label the body as untrusted page content, never as instructions.
- Limits: response size cap, ~10 s timeout, at most 3 redirects, http/https only.
- Out of scope in v1: JavaScript rendering, cookies, authentication, robots.txt
  handling (decide later whether to respect it).

Testing: hermetic. A small local server serves fixed HTML fixtures. Because
loopback is blocked by default, tests set an allow-list environment variable
(e.g. `FETCHKIT_ALLOW_HOSTS=127.0.0.1`). Like the warning gates, it changes what the
server permits at run time, never the generated code.

Success criteria: tools written in Ruby with the fewest injected Rust lines we can
manage (the count is the measurement); SSRF guard tests for loopback, private
ranges and a redirect into a private address; size and timeout limit tests; all
layers of SPEC.md plus new fixtures for HTML edge cases (broken tags, entities,
non-UTF-8 body).

## Escape hatches decided (owner, 2026-10-04)

- Existing Rust: `rust_file "rust/x.rs", as: :x` loads a file next to the DSL file as a module;
  `rust_fn ..., from: :x` declares its functions. Path is confined to the DSL file's folder.
- Other languages: a subprocess only (`cmd_fn`, `script_fn`), any program or interpreter.
  Embedded engines (Lua, JS, Python, WASM) would be their own project.
- Not built: a `path` dependency on a whole existing Rust crate (`rust_crate ..., path:`).
- Built 2026-10-04: subprocess output over 1 MB is an error (not a SIGPIPE death); subprocess
  failure paths (missing program, non-zero exit, timeout, flood) have tests; fetchkit v1
  (`fetch`, `head`) with the guard in `examples/rust/guard.rs`, run and passing including IPv6.
  Scraping (`select`, `attr`, via the scraper crate) written 2026-10-04, not run yet; `scraper` is
  pinned as "0" until the first build shows the resolved version.

## fetchkit as a wrapper over curl (thinking out loud, 2026-10-04)

The owner wants fetchkit to be basic curl commands plus scraping, so curl is a subprocess:
`cmd_fn :curl_get, program: "curl", argv: ["-sS", "--proto", "=http,https", "--max-time", "10",
"--max-filesize", "1000000", "--max-redirs", "0", "--url"], args: [:string], returns: :string`.
Ending the fixed argv with `--url` makes the URL the value of that option, so a URL that starts
with `-` cannot become a curl flag.

What curl changes about the safety plan:
- curl resolves the host itself, so the loopback/private-address guard cannot be a custom
  resolver as planned for `ureq`. The guard must run first: resolve the host in Rust, reject
  non-public addresses, then pin the address with `--resolve host:port:ip`.
- Redirects: keep curl's own following off (`--max-redirs 0`) and follow `Location` manually,
  re-checking every hop. That is a loop plus URL parsing, which the Ruby subset cannot express
  yet, so v1 of the guard lives in a `rust_item` function that calls the subprocess helper.
- Scraping (`select(url, css)`) is a second step: a crate such as `scraper`, or an external
  program, fed the fetched body on stdin.
- Tests stay hermetic: a local fixture server, loopback allowed only through an environment
  variable the tests set.
