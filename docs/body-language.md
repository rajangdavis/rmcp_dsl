# The body language

The Ruby subset a tool body may use, and the helpers it can call.

_See also: [README](../README.md)._

## What a tool body may contain

Ordinary Ruby from a deliberately small subset. Anything else is a compile error that says what to use
instead. `rmcp_dsl skill` writes the complete, generated reference; the outline:

- **Types:** `:i32`, `:i64`, `:f64`, `:bool`, `:string`, lists of strings, integers or floats
  (`:string_list`, `:i64_list`, `:f64_list`, also `list(:string)`/`list(:i64)`/`list(:f64)`), lists of objects
  (`field :offices, list(:Address)`, read `offices[0]&.city` or, in a block, `o.city`), typed maps with
  scalar, object or nested-map values (`map(:i64)`, `map(:Address)`, `map(map(:i64))`), and fields of a nested
  object (`address.city`, or `address&.city` when the object is optional; an unguarded `address.city` on it is
  refused; an object cannot be put in a string, read its fields).
- **Syntax:** literals, locals (`name = expr`, no reassignment; a name must be snake_case and not a Rust
  keyword), arithmetic and comparisons, `&& || !`,
  `if`/`elsif`/`else`, `unless`, ternary, `case`/`when`, string interpolation, guard clauses
  (`return "x" if cond`, `raise "msg" unless cond`), and blocks with one parameter. A body's block
  parameters are the params field names, in order; they cannot be renamed or aliased.
- **Strings:** `upcase downcase strip capitalize length split partition chars lines reverse tr delete
  squeeze index start_with? end_with? include? empty? match? =~ gsub sub to_i`, slicing `s[start, len]` and
  `s[i]`, `s * n`, and `Integer(text, 10)`. `gsub`/`sub` take a string or regex literal, or a block; `=~`
  takes a regex literal and gives the character index of the first match (nil when none). A string literal is a
  borrowed `str`: `s + "x"` concatenates, but `"x" + s` is refused; use interpolation or `.to_s` when the literal
  comes first.
- **Lists:** `split`, array literals, `n.times`, `a.upto(b)`, ranges `(a..b)`, and `map select reject
  find any? all? count sum min max sort uniq reverse first last [] join include? empty?`; `each` is a
  statement that runs its block for side effects and returns the list. Blocks may use arithmetic, `to_i`,
  `raise` and `return`. A `list(:Address)` supports `length size empty? first last []
  each map select reject find any? all? count reverse`; ordering, equality and stringification (`sort`,
  `uniq`, `include?`, `join`, `sum`, `min`, `max`) are refused.
- **Maps.** A typed map is read-only. `m["k"]` is nil-able, and `fetch key? keys values size empty? merge`
  read it; `to_json` writes it as a JSON string (a value serde cannot write is an error result); `map`,
  `select`, `reject` and `each` take a `|k, v|` block (the String key and the value): `map` returns a list
  built from the block, `select`/`reject` a new map of the same value type, and `each` runs the block for
  side effects and returns the map.
- **Nil-able values.** Methods that return nil in Ruby (`first`, `last`, `xs[i]`, `index`, `=~`, optional fields,
  nil-able binding results) must be used through `|| default`, `|| raise("msg")`, `.nil?` or `.to_s`, so a
  missing value is never silently used. `||` is for nil-able values only: on a required one it is refused, so a
  required list takes no `|| []` fallback. An optional nested object is read with `&.` (`address&.city`).
- **Moves.** A local is moved when it is used, and `||` moves its left operand, so `x || default`
  followed by another read of `x` is rustc's `E0382` (`use of moved value`). Make each path yield the
  value once (pick the result in one expression) rather than reusing a moved local.
- **Errors.** `raise "msg"` and integer overflow end the call with an error result (`isError: true`).
  `return value` ends it with that string, even from inside a list block. There is no `begin`/`rescue`:
  failures are values, so a retry is written as data (`a = attempt(x); b = if a == "" then attempt(y) else "" end`)
  rather than control flow.
- **Request context.** A tool body may read `client_name`, `client_version` and `protocol_version` (each a
  string or nil), `request_id` (a string), `progress_token` (a string or nil, when the client asked for
  progress) and `cancelled?` (a bool).
- **Files.** `file_text(:name)` is the text of a file declared with `file "path", as: :name`, read from disk on
  each call (an error result if it cannot be read); it works in a helper too. `file_path(:name)` is the path it
  is read from (the `env:` variable when set), for a message or a traceback. `entry(:name, :fn)` is the string
  `"fn"`, refused unless `:fn` is in the file's `entries:`, and `entry_args(:name, :fn, key: value, ...)` is the
  arguments as JSON text, each key and type checked against `def fn` (its one TypedDict parameter or its plain
  parameters); nil is `null`, and a nil-able value needs a field that allows `None`. A `Literal["a", "b"]`
  field takes a string literal from its list, or a parameter whose `enum:` holds only those values.
- **Settings.** `setting(:name)` reads a value the server declared with `setting :name, env: "..."`, always as a
  string, so a numeric one is parsed in the body (`setting(:port).to_i`, Ruby's rules, an error result if it does
  not fit). It works only in a tool, prompt or resource body, not in a helper or a binding, where the value must
  be passed in.
- **Statements.** `progress(value, total:, message:)` reports progress (sent only when the client supplied
  a token); `log(level, message)` sends `notifications/message`; `hide_tool(:name)` and `show_tool(:name)`
  change the advertised tool list — clients get `notifications/tools/list_changed`, a hidden tool leaves
  `tools/list` and `tools/call` refuses it.
- **Peer calls.** Only a tool body may make them. `elicit(message, schema: { ... })` asks the client for
  input (`elicitation/create`) and gives a result with `.action` (`accept`, `decline` or `cancel`) and
  `.content`; `roots()` asks the client for its roots (`roots/list`) and gives a list whose entries have
  `.uri` and a nil-able `.name`; `sample(prompt, max_tokens:, system:, temperature:, stop:)` asks the
  client for a completion (`sampling/createMessage`) and gives `.text` (nil-able), `.model`, `.role` and a
  nil-able `.stop_reason`. Such a tool compiles async and can fail.
- **Feature gates.** `log`, `roots()` and `sample(...)` need `feature :logging`, `:roots` and `:sampling`
  declared, which also advertises the capability. The three are deprecated upstream by SEP-2577 but still
  provided by the pinned rmcp: declaring one emits `N-DEPRECATED-FEATURE`, and the generated call is scoped
  with `#[allow(deprecated)]` so the crate stays warning-free.
- **Cancellation.** rmcp cancels a request when `notifications/cancelled` arrives, so a body that checks
  `cancelled?` around its awaits in a loop can stop early. Blocking escapes (`cmd_fn`/`script_fn`, blocking
  bindings) run to completion and are not interruptible.
- **Integers follow Ruby:** `/` rounds down and `%` takes the sign of the divisor. `Rust::Int32(a) / b`
  opts into Rust's truncating behaviour. Arithmetic is overflow-checked and a result that does not fit
  comes back as an error that says what, where and how to fix.
- **Strings follow Ruby:** `strip` is not Rust's `trim`. `Rust::Str(s)` opts into Rust's `str` behaviour: `trim`,
  `strip` (the same as `trim`, with notice `N-STR-STRIP-RUST`), `to_lowercase`, `to_uppercase`, `len` (bytes),
  `lines`, `split(pat)`, `contains(pat)`, `starts_with?(pat)` and `replace(from, to)`; `to_s` leaves it for a
  plain string, which a body must do before returning it.
- The last expression is the result and must be a string.

The DSL is strict on purpose so the file says exactly what the server does and the generated Rust stays
warning-free. Unused locals, block parameters, declarations, helpers and params are all compile errors.
Regex literals are translated to Rust's `regex` crate; features the engines disagree on (lookaround,
backreferences, `\h`, `\Z`, possessive quantifiers) are rejected.

`make probe` runs about fifty one-line bodies through the compiler and prints which Ruby it accepts today.

## Helpers

Logic that more than one tool needs goes in a helper, with its types written out:

```ruby
helper :checked_host, args: [:string], returns: :string do |url|
  raise "not a valid URL: #{url}" unless Url.valid?(url)
  (Url.host(url) || raise("URL has no host")).delete("[]")
end

tool :host, params: :UrlParams, description: "The checked host" do
  body do |url|
    checked_host(url)
  end
end
```

Types are `:string :i32 :i64 :f64 :bool :string_list :i64_list :f64_list`, and a trailing `?` makes an argument or a
result nil-able (`:string?`, `:i64_list?`, ...). A helper may also take keyword parameters, declared with
`kw: { limit: [:i32, false] }` and a literal default in the block (`do |text, limit: 0| ... end`), called by
name in any order (`h(text, limit: 3)`) or omitted for the default. A helper can only call helpers declared
above it, so recursion cannot happen. A failure inside a helper becomes an error result in the caller; a
helper that cannot fail compiles to a plain function. A helper that nothing calls is an error. Sorbet cannot
know names declared in the DSL, so `rmcp_dsl rbi FILE...` writes their signatures to
`sorbet/rbi/rmcp_dsl/dsl_helpers.rbi` (`make rbi-helpers`; `make check` fails if it is stale) and files that
call helpers stay `# typed: true`. Two files declaring one helper with different types are refused. The
compiler checks every call regardless. `examples/webkit.rmcp.rb` uses four.

**Helper rules.** A helper cannot read a setting. `setting(:x)` works only in a tool, prompt or resource body, so a helper that needs one takes it as an argument. In a body, block parameters are the params field names exactly, with no aliasing: `|image_ref|` must name a field. A local must be snake_case and may not be a Rust keyword, such as `ref` or `type`.

**Moves.** Ruby reads a local without using it up, but Rust moves a value. So the compiler clones a `String`, list, map or JSON local where Rust would move it: as the value of an `if`, `unless` or `case` branch, on the right of `a = b`, and on the left of `||` when that side is nil-able. The local stays readable afterwards. Generated structs and binding (opaque) types are not cloned and still move. For those, restructure the body so each value is moved on one path only, and is not read after the move.

**Async.** A `rust_fn` or binding function declared `async: true` is an `async fn`; a body that calls any
async function is compiled `async fn` too. Async is inferred, so a caller never repeats `async: true`:
the declaration is a function's own, not its callers. A declaration's `returns:` is the eventual value
(not a future), and a call site is awaited, with `?` when the callee can fail. An async call is allowed
in a tool body, a helper, a prompt body or a resource body. A `gsub`/`sub` block compiles to a plain
Rust closure and a Ruby-compiled binding has no async context, so an async call there is refused with a
message that names the reason the callee is async. An async helper that is recursive would need
`Box::pin`, so a recursive async helper cycle is refused; `async: true` on `cmd_fn`/`script_fn` is
refused because a subprocess is blocking. A tool future must be `Send` (rmcp's requirement) and the
compiler never boxes one, so a non-`Send` value held across an `.await` in a `rust` template (a
`MutexGuard`, an `Rc`, a `RefCell` borrow) is rustc's `Send` error, not a DSL error.
