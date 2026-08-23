# OneOf

<!-- generated:begin id=page -->
Words available in the OneOf body.

*The tables on this page are generated from the language's own
aggregate-local syntax tables (`lib/hecksagain/language/**/*.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*
<!-- generated:end -->

This whole context is legacy now (S3, ADR 0025 — "closed sets lose the
wrapper block"): `OneOf` used to be what `value_object do ... end`
opened by writing `one_of do ... end`, and `member` was only ever legal
nested inside it. Live source spells a single-field closed set with
`attribute`'s own `one_of:` keyword instead, and a multi-field one with
bare `member` lines directly in the value object's own body — both
documented on value_object.md, which is also where `AccountKind`
(banking's own worked example, quoted below in its CURRENT form) and
`StatementFrequency` actually live now.

This context still exists only because frozen era text still writes the
old shape — `EraGuard.shadow_parse`'s own S0a bridge reads it — and
writing it in live source refuses (see `member`'s own example, below).

```ruby skip
# examples/banking/bluebook/, as it reads today
value_object "AccountKind" do
  attribute :name, String, one_of: ["current", "savings", "reserve"]
end
```

## member

<!-- generated:begin word=member -->
`member members` — opens a `Member` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | pairs | true | members |
<!-- generated:end -->

One legal value of the closed set, only ever legal nested inside the
now-legacy `one_of do ... end` wrapper (see value_object.md's own
`member` section for the live, bare spelling). Writing the wrapper in
live source refuses before any `member` line inside it is even read:

```ruby
Hecks.bluebook("MemberGone") { aggregate("Thing") { identified_by :thing_id; value_object("Kind") { attribute :value, String; one_of { member value: "a" } } } }  # ~> Malformed: one_of do ... end wrapper is gone
```

