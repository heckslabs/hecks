# Adapter

<!-- generated:begin id=page -->
Words available inside `adapter do ... end`.

*The tables on this page are generated from the language's own
aggregate-local syntax tables (`lib/hecksagain/language/**/*.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*
<!-- generated:end -->

Real adapters, not invented for this page — `Memory`, the one every
domain in this repo actually binds against:

```ruby boot
Hecks.adapter("reference_memory") do
  port   "reference_persistence"
  field  :namespace
  secret :api_key
end
```

## port

<!-- generated:begin word=port -->
`port port` — fills `port`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | port |
<!-- generated:end -->

Which resource port this adapter implements — free text naming an already-declared `.port` by its own name, not a formal reference (an adapter can be declared before or after the port it implements). Optional to declare at all: `field`/`secret` can each be used alone, without ever naming a port.

```ruby
runtime.registry.adapters["reference_memory"].port  # => "reference_persistence"
```

## field

<!-- generated:begin word=field -->
`field fields` — fills `fields`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | fields |
<!-- generated:end -->

Names one plain config value a world's own wiring for this adapter must supply (a database name, a namespace, ...) — called once per value, accumulating. Kept apart from `secret`: both name a required value, but only `secret` marks it sensitive.

```ruby
runtime.registry.adapters["reference_memory"].fields  # => [:namespace]
```

## secret

<!-- generated:begin word=secret -->
`secret secrets` — fills `secrets`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | secrets |
<!-- generated:end -->

Names one SENSITIVE config value a world's own wiring for this adapter must supply (an API key, a credential, ...) — the same shape as `field`, kept in its own list so a deployment mechanism can treat it differently (a secrets manager rather than plain settings).

```ruby
runtime.registry.adapters["reference_memory"].secrets  # => [:api_key]
```

