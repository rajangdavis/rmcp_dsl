# Spec: typed record within the opaque-type rule (gap #3)

Status: proposal for the owner. No code yet. Source: `rmcp-for-blender/docs/rmcp-dsl-gaps.md` #3.

## Problem

> What is missing is a *typed* record — a `record :Row do ... end` usable in binding returns and outputs —
> so the schema, the structured result and the editor types can describe a row. Until then,
> `Html.select`/`Html.attr` stay column-oriented ... and row data is opaque.

## The rule this must respect

Complex JSON enters only through binding-declared opaque types (`class Value < RmcpDsl::Opaque` with
`type_rust`, `bindings.rb` `opaque`; `CompositeTypes::Opaque`); there is no dynamic Json in the DSL. So the
record is **not** declared in the DSL file as `record :Row do`. The Rust struct stays owned by a binding;
the binding additionally tells the compiler its fields.

## Surface

In `bindings/html.rb`:

```ruby
class Row < RmcpDsl::Opaque
  type_rust "html::Row", wire: true
  field :text, String
  field :href, T.nilable(String)
  field :rank, I64
end

sig { params(page: String, selector: String).returns(T::Array[Row]) }
def self.rows(page, selector) ... end
```

In the DSL:

```ruby
output :Places do
  field :places, list(Html::Row)
end
tool :scrape, params: :P, output: :Places, description: "..." do
  body do |url|
    { places: Html.rows(Http.get(url), ".place-card") }
  end
end
tool :first_link, params: :P, description: "..." do
  body { |url| Html.rows(Http.get(url), "a").first.href || "none" }
end
```

Fields are the scalar and list types a binding sig already accepts (`String`, `I32`, `I64`, `Float`,
`T::Boolean`, `T::Array[...]` of those) and `T.nilable` of them. A record field of another record type is
not allowed in this version.

## Semantics

- A record is an opaque type that also lists fields. A one-line `class` stays plain opaque. Compatibility
  is total: nothing that compiles today changes.
- `wire: true` is required to use a record as an `output`/`params` field or in a result (the existing
  check in `opaque_field_type`); the schema comes from the Rust type's `JsonSchema`, as for any wire opaque
  type. The declared `field`s do not generate a schema; they describe it.
- The compiler verifies the declaration with rustc: `emit.rb` adds a conformance function per record,
  `fn _check_Row(r: &html::Row) { let _: &String = &r.text; let _: &Option<String> = &r.href; ... }`, mapped
  back to the binding file's `field` line. A Rust struct that drifts from its declaration fails the
  build at the declaration, not at a tool.
- The DSL may read a field: `row.text` (Ruby attribute-reader semantics: a value of the field's type,
  owned, `.clone()` for non-Copy; moves follow the D1 liveness rule). It may not construct a record, assign
  a field or call methods: records come from binding functions only.
- A binding sig may return `Row`, `T::Array[Row]` and `T.nilable(Row)`.
  `T::Array[Row]` in a DSL list position gets the symbol `:"list<ext<Html::Row>>"`; iteration and
  `map`/`first`/`length` reuse the paths lists of params structs take (`struct_list?` in `body.rb`) with the
  element resolved through `CompositeTypes::Opaque`.

Refusals:

| Case | Message |
|---|---|
| `field` outside a type | ``field belongs inside `class Name < RmcpDsl::Opaque` `` |
| bad field type | ``field `rank`: unsupported type `Integer` (supported: String, I32, I64, Float, T::Boolean, T::Array of those, T.nilable of those); use I32 or I64`` |
| duplicate field | ``record `Row` declares field `text` twice`` |
| record in record | ``field `inner`: a record cannot hold another record (not yet)`` |
| unknown field read | ``Html::Row has no field `hrf` (its fields: text, href, rank); did you mean `href`?`` |
| plain opaque read | the existing ``Html::Value is an opaque value with no methods of its own`` |
| assign / construct | ``Html::Row is read-only here; a binding function creates records`` |
| not wire, in a schema | the existing ``... cannot be a field: its binding does not say `wire: true` ...`` |
| unknown list element | ``list(Html::Rw): binding Html has no type `Rw` (its types: Value, Row); did you mean `Row`?`` |

## Mapping onto the code

- `bindings.rb`: `opaque` currently demands exactly one `type_rust` line (message "holds one line"). Allow
  `field NAME, TYPE` lines after it, parsed with the existing `type(node)`; `Opaque` Struct gains `fields`.
  `type` / `scalar_or_opaque` (bindings.rb ~188) accept `T::Array[Row]`.
- `composite_types.rb`: `Opaque::Entry` gains `fields`; `Opaque.reset(entries)` takes them from the IR
  (`srv["opaque_types"]` entries get `"fields"`), because Emit holds no state. Add a `list<ext<...>>`
  symbol next to `OBJECT_LIST_FIELD`, and `list(Mod::Name)` parsing in the field-type reader
  (`reader.rb` `opaque_field_type`, ~897).
- `body.rb`: field read on an `ext<...>` receiver with fields (the refusals at body.rb ~254 and ~593
  keep firing for plain opaque types); typing via the `OPT`/`OPT_OF` tables for `T.nilable` fields.
- `emit.rb`: `rust_type` already maps opaque symbols (~514, ~659); add the list form and the `_check_` fns;
  the source map needs a binding-file reference, which `use_dsl.md` introduces (`dsl_file` per range).
- The OpenAPI path (`OpenApi::OpaqueName`, `openapi.rb`) is untouched: its `OpenApi::Value` stays plain.

## Editor support

- Diagnostics: the table above on the DSL or binding line (binding files are already analysed through the
  DSL that loads them; a fault in a `field` line is reported on the binding's own line, which wants the
  per-file diagnostics of `use_dsl.md`).
- Hover: on `row.text` the field's type; on `Html::Row` the record with its fields (`lsp/hover.rb`,
  `TypeNames::Collector` kind `"field"`). Completion: field names after `.` on a record value
  (`completion.rb`). Go-to-definition on a record type or field: the binding's `class`/`field` line.
- Inlay hints: types of `rows` and `row.text` locals (`inlay_hints.rb`).
- Types: `Rbi` shows binding sigs through `T::Array[Html::Row]`; the record has a generated `Html::Row`
  class with typed readers in the rbi so Sorbet agrees (`rbi.rb`, generated from the IR's `opaque_types`).
- `docs/bindings.md` (opaque section), `skill.rb` worked example, `docs.rb` keyword docs for `field`
  inside a binding type.

## Tests

- `test_opaque.rb`: a record with fields; plain opaque unchanged; every refusal row.
- `test_bindings.rb`: parse of `field`, `T::Array[Row]` returns, `T.nilable(Row)`.
- A new example `examples/rowkit.rmcp.rb` plus `examples/bindings/html.rb` and a golden `main.rs`;
  `rustc` must accept the `_check_` fns, and a deliberately drifted Rust struct must fail at the `field` line.
- `test_lsp_hover.rb`, `test_lsp_completion.rb`, `test_lsp_definition.rb`: row field rows above.
- `test_rbi.rb`: the generated record class.
- Schema: output JSON schema for `list(Html::Row)` contains the Rust type's fields (e2e script).

## Open questions

1. The gap asks for `record :Row do ... end` in the DSL. This spec moves it into the binding to honour
   "complex JSON only through binding-declared opaque types". Is that the intended reading?
2. `field` lines in the `Opaque` class (this spec), or a separate `record Row` form in bindings?
3. Records in records and `Hash`-typed fields: not in this version; needed for the HTML use case?
4. Should the conformance check be mandatory (this spec), or opt-out for a type whose Rust definition the
   compiler cannot see (a crate type rather than a `rust_file` module)? A crate type could not be checked
   by a text scan, but rustc checks it anyway; confirm there is no case where it cannot.
5. Ordering with the rest: this wants `use_dsl.md`'s per-file diagnostics for good binding-line errors.
   Build `use_dsl` first?
