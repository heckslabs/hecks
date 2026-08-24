# Translation

<!-- generated:begin id=page -->
Words available inside `data_translation do ... end`.

*The tables on this page are generated from the language's own
aggregate-local syntax tables (`lib/hecks/language/**/*.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*
<!-- generated:end -->

A translation names how one era of a domain's own stored data becomes
the next — one file, one `from:`/`to:` pair, and one `aggregate` block
per aggregate that moved:

```ruby boot
Hecks.data_translation("ReferenceDomain", from: "1", to: "2") do
  aggregate "Account" do
    rename :old_field, to: :new_field
  end

  retired "LegacyAggregate"
end
```

## aggregate

<!-- generated:begin word=aggregate -->
`aggregate name, was: do ... end` — opens a `TranslationAggregate` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
| `was:` | text | false | was |
<!-- generated:end -->

One aggregate's own move from the pinned old era to the pinned new one — a table of rules (`rename`, `move`, `convert`, `drop`, `retype`, `compute`, `rekey`, `backfill`), see the TranslationAggregate reference page for the words inside. `was:` names the aggregate's OWN prior name, for an aggregate that was renamed outright rather than just having fields renamed inside it — leave it unset when the aggregate kept its name.

```ruby
runtime.registry.translations.last.aggregates.map(&:name)  # => ["Account"]
```

## retired

<!-- generated:begin word=retired -->
`retired name` — fills `retired`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
<!-- generated:end -->

Names an aggregate the new era drops outright — not renamed (that is `aggregate ... was:`), not moved into another one, simply gone. Called once per retired aggregate, accumulating; a deliberate acknowledgment, the same reason `drop` exists one level in.

```ruby
runtime.registry.translations.last.retired  # => ["LegacyAggregate"]
```

