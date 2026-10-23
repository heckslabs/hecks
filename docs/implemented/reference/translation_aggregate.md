# TranslationAggregate

<!-- generated:begin id=page -->
Words available inside `aggregate do ... end`.

*The tables on this page are generated from the language's own
aggregate-local syntax tables (`lib/hecks/language/**/*.bluebook`)
by `hecks language_run.project_reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*
<!-- generated:end -->

One aggregate's own table of rules, exercised together — every rule
but `unresolved` (which only ever refuses; see its own section below):

```ruby boot
Hecks.data_translation("ReferenceDomain2", from: "1", to: "2") do
  aggregate "Account" do
    rename  :old_field, to: :new_field
    move    "old.path",  to: "new.path"
    convert "status",    to: "state", values: { "open" => "active" }
    drop    :legacy_field
    retype  "OldType",   to: "NewType"
    derive  :label,      as: 'concat(upper(code), "-", lookup(tier, {"gold": "G"}, "S"))'
    backfill :standing, default: "good"
  end
  aggregate "Member" do
    derive :email, as: "lower(name.value)"
    rekey_to :email
  end
end
```

## rename

<!-- generated:begin word=rename -->
`rename old_name, to:` — fills `renames`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | old_name |
| `to:` | symbol | true | to |
<!-- generated:end -->

A field kept its structure and only its name changed — the smallest rule, and the one every migration reaches for first. Accumulates into a plain old-name-to-new-name table.

```ruby
runtime.registry.translations.last.aggregates.first.renames  # => {old_field: :new_field}
```

## move

<!-- generated:begin word=move -->
`move old_path, to:` — fills `moves`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | old_path |
| `to:` | text | true | to |
<!-- generated:end -->

One field crossing a value-object boundary — a scalar becoming a VO member, a VO member becoming a scalar, or a rename across the move. Paths are dotted (`"price.cents"`) to reach a VO member, bare otherwise — text rather than `rename`'s bare symbol, since a path can be more than one name.

```ruby
runtime.registry.translations.last.aggregates.first.moves.first.to_h  # => {from: "old.path", to: "new.path"}
```

## convert

<!-- generated:begin word=convert -->
`convert old_path, to:, values:` — fills `converts`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | old_path |
| `to:` | text | true | to |
| `values:` | literal | true | values |
<!-- generated:end -->

A value with nothing structural in common with its replacement — declared as an exhaustive table, not computed, so every value that can appear in old data has a named destination. `values:` is captured as arbitrary, unvalidated data (the same `LiteralText` shape `provenance` already uses), since what a real migration's own lookup table holds is open-ended.

```ruby
runtime.registry.translations.last.aggregates.first.converts.first.to_h  # => {from: "status", to: "state", values: {"open" => "active"}}
```

## drop

<!-- generated:begin word=drop -->
`drop name` — fills `drops`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | name |
<!-- generated:end -->

A declared, deliberate acknowledgment that an attribute's data does not survive the move — the honest alternative to letting it silently vanish because nothing named it.

```ruby
runtime.registry.translations.last.aggregates.first.drops  # => [:legacy_field]
```

## retype

<!-- generated:begin word=retype -->
`retype old_type, to:` — fills `retypes`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | old_type |
| `to:` | text | true | to |
<!-- generated:end -->

A value object's or entity's own TYPE NAME changed, its member structure unchanged. Stored data never carries the type name, so nothing moves — this declares that the pair of names means the same shape, which is what lets the era diff accept it.

```ruby
runtime.registry.translations.last.aggregates.first.retypes.first.to_h  # => {from: "OldType", to: "NewType"}
```

## derive

<!-- generated:begin word=derive -->
`derive to, as:` — fills `derives`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | to |
| `as:` | text | true | as |
<!-- generated:end -->

A new field computed from the record's own text, in a small language with no storage engine in it: `lower`, `upper`, `concat`, `replace`, `lookup`, string literals, `null`, and fields named by dotted path (`name.value`). It reads the data as stored in the held era, so it runs before every other rule, and the fields it reads stay where they are; `drop` removes them. A field that is missing or not text has no value, a function with a valueless argument has none either, and a record where the whole expression has no value gets no new field. `lookup` takes a table and a fallback (a string, or `null` for none). Case folding is ASCII only and `replace` is plain text, not a pattern, so the in-process rewrite and the Postgres head agree on every record. Unlike `compute`, it needs no approval and runs on any adapter.

```ruby
runtime.registry.translations.last.aggregates.first.derives.first.to_h  # => {to: "label", expression: "concat(upper(code), \"-\", lookup(tier, {\"gold\": \"G\"}, \"S\"))"}
```

## rekey_to

<!-- generated:begin word=rekey_to -->
`rekey_to to` — fills `rekeys`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | to |
<!-- generated:end -->

Makes the aggregate's identity the value of a field a `derive` computes, so the expression is written once. The derive must be declared before it, and an aggregate is rekeyed once. A record keeps its old id where the derive has no value. Unlike `rekey`, it is pure: no SQL, no approval, and `Lineage#translate` changes the id in process the same way the Postgres head does.

```ruby
runtime.registry.translations.last.aggregates.last.rekeys.first.to_a  # => ["email"]
```

## backfill

<!-- generated:begin word=backfill -->
`backfill name, default:` — fills `backfills`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | name |
| `default:` | literal | true | default |
<!-- generated:end -->

A newly added, required attribute — the addition-side sibling of `drop`. Nothing to rename, move, or convert FROM, since old data never held this field at all; `default:` (captured the same open-ended way `convert`'s `values:` is) is what an existing record reads until the next command against it writes a real value.

```ruby
runtime.registry.translations.last.aggregates.first.backfills.first.to_h  # => {name: :standing, default: "good"}
```

## unresolved

<!-- generated:begin word=unresolved -->
`unresolved name, candidates:`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | name |
| `candidates:` | list | false | candidates |
<!-- generated:end -->

The scaffold writes this where it cannot decide on its own — a file carrying one can only boot into this refusal, never a guess. `candidates:` names what the scaffold considered and rejected, folded into the refusal message; omitted, the message says no candidate matched at all.

```ruby
Hecks.data_translation("ReferenceDomainBad", from: "1", to: "2") { aggregate("Account") { unresolved :some_field } }  # ~> Malformed: leaves :some_field unresolved
```

