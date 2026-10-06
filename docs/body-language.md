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
- **Syntax:** literals, locals (`name = expr`, no reassignment), arithmetic and comparisons, `&& || !`,
  `if`/`elsif`/`else`, `unless`, ternary, `case`/`when`, string interpolation, guard clauses
  (`return "x" if cond`, `raise "msg" unless cond`), and blocks with one parameter.
- **Strings:** `upcase downcase strip capitalize length split partition chars lines reverse tr delete
  squeeze index start_with? end_with? include? empty? match? =~ gsub sub to_i`, slicing `s[start, len]` and
  `s[i]`, `s * n`, and `Integer(text, 10)`. `gsub`/`sub` take a string or regex literal, or a block; `=~`
  takes a regex literal and gives the character index of the first match (nil when none).
- **Lists:** `split`, array literals, `n.times`, `a.upto(b)`, ranges `(a..b)`, and `map select reject
  find any? all? count sum min max sort uniq reverse first last [] join include? empty?`; `each` is a
  statement that runs its block for side effects and returns the list. Blocks may use arithmetic, `to_i`,
  `raise` and `return`. A `list(:Address)` supports `length size empty? first last []
  each map select reject find any? all? count reverse`; ordering, equality and stringification (`sort`,
  `uniq`, `include?`, `join`, `sum`, `min`, `max`) are refused.
- **Maps.** A typed map is read-only. `m["k"]` is nil-able, and `fetch key? keys values size empty? merge`
  read it; `map`, `select`, `reject` and `each` take a `|k, v|` block (the String key and the value): `map`
  returns a list built from the block, `select`/`reject` a new map of the same value type, and `each` runs
  the block for side effects and returns the map.
- **Nil-able values.** Methods that return nil in Ruby (`first`, `last`, `xs[i]`, `index`, `=~`, optional fields,
  nil-able binding results) must be used through `|| default`, `|| raise("msg")`, `.nil?` or `.to_s`, so a
  missing value is never silently used. An optional nested object is read with `&.` (`address&.city`).
- **Errors.** `raise "msg"` and integer overflow end the call with an error result (`isError: true`).
  `return value` ends it with that string, even from inside a list block.
- **Request context.** A tool body may read `client_name`, `client_version` and `protocol_version` (each a
  string or nil), `request_id` (a string), `progress_token` (a string or nil, when the client asked for
  progress) and `cancelled?` (a bool).
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
