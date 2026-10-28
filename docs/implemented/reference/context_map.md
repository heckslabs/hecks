# ContextMap

<!-- generated:begin id=page -->
Words available inside `context_map do ... end`.

*The tables on this page are generated from the language's own
aggregate-local syntax tables (`lib/hecks/language/**/*.bluebook`)
by `hecks language_run.project_reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*
<!-- generated:end -->

## context

<!-- generated:begin word=context -->
`context contexts, team:` — fills `contexts`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | contexts |
| `team:` | text | false | contexts |
<!-- generated:end -->

`context` declares one context of the system and, if known, the team that owns it.

```ruby
shop = Hecks::Bluebook::DSL::ContextMapBuilder.build("Shop") { context "Ordering", team: "storefront" }
shop.contexts.map(&:team)  # => ["storefront"]
```

## relate

<!-- generated:begin word=relate -->
`relate key:, as:, published:, of:, acknowledges:` — fills `relationships`

| argument | kind | required | fills |
|---|---|---|---|
| `key:` | pairs | true | relationships |
| `as:` | symbol | true | relationships |
| `published:` | list | false | relationships |
| `of:` | list | false | relationships |
| `acknowledges:` | literal | false | relationships |
<!-- generated:end -->

`relate "Upstream" => "Downstream", as: :kind` declares that the upstream context supplies and the
downstream one consumes. `published:` lists the upstream events a downstream may depend on,
`of:` the names a shared kernel holds in common, and `acknowledges:` the findings about the
relationship that it allows, each with the reason. A relationship can carry only a finding
about itself: a coupling with no relationship, or one the map declares apart, is fixed by
declaring the relationship and not by allowing the finding.

```ruby
shop = Hecks::Bluebook::DSL::ContextMapBuilder.build("Shop") do
  context "Billing"
  context "Ordering"
  relate "Billing" => "Ordering", as: :conformist, acknowledges: { conformist_translates: "Ordering keeps its own words" }
end
shop.relationships.first.acknowledges?(:conformist_translates)  # => true
```

## separate_ways

<!-- generated:begin word=separate_ways -->
`separate_ways separate_ways, separate_ways` — fills `separate_ways`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | separate_ways |
| positional 2 | text | true | separate_ways |
<!-- generated:end -->

`separate_ways "A", "B"` declares two contexts apart: any coupling between them is an error.

```ruby
shop = Hecks::Bluebook::DSL::ContextMapBuilder.build("Shop") do
  context "Billing"
  context "Ordering"
  separate_ways "Ordering", "Billing"
end
shop.separate?("Billing", "Ordering")  # => true
```

