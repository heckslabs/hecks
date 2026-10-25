# Adapter

<!-- generated:begin id=page -->
Words available inside `adapter do ... end`.

*The tables on this page are generated from the language's own
aggregate-local syntax tables (`lib/hecks/language/**/*.bluebook`)
by `hecks language_run.project_reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*
<!-- generated:end -->

Real adapters, not invented for this page — `Memory`, the one every
domain in this repo actually binds against:

```ruby boot
Hecks.adapter("reference_memory") do
  port   "reference_persistence"
  field  :namespace
  field  :region, default: "us-east-1"
  secret :api_key
end

Hecks.adapter("reference_sql") do
  port     "reference_persistence"
  provides "set_transform"
end

Hecks.adapter("reference_plugin") do
  answers_query "Calendar::Event.Occurrences"
  runs "occurrences.wasm"
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
`field fields, default:` — fills `fields`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | fields |
| `default:` | literal | false | default |
<!-- generated:end -->

Names one plain config value a world's own wiring for this adapter must supply (a database name, a namespace, ...) — called once per value, accumulating. Kept apart from `secret`: both name a required value, but only `secret` marks it sensitive.

```ruby
runtime.registry.adapters["reference_memory"].fields  # => [:namespace, :region]
```

`default:` is the value a field takes when a world gives none, so the adapter never carries a
fallback of its own: it reads the setting it declared and the framework has already filled it.
A world's own value always wins, and a world that writes `:default` for a field asks for the
declared default. A string default may hold `{name}` or `{storage_name}`, filled from the
aggregate the adapter is built for (`field :database, default: "data/{storage_name}.db"`); any
other placeholder is refused when the adapter is declared. A default of `false` or `nil` is a
default, not an absent one.

```ruby
runtime.registry.adapters["reference_memory"].declared_defaults  # => {region: "us-east-1"}
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

## answers_query

<!-- generated:begin word=answers_query -->
`answers_query answers` — fills `answers`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | answers |
<!-- generated:end -->

Names one query a plugin answers, written in full as `Chapter::Aggregate.Query`, called once per
query. The query is declared in the bluebook with `returns`, as any query answered from outside
is; what differs is that no hecksagon line binds it. At boot the runtime binds each `returns`
query no hecksagon binds to the one plugin that says it answers it, so a package that ships its
plugin beside its bluebook needs no wiring in the project that vendors it. Two plugins naming
one query is refused rather than chosen between, and a hecksagon `answers_query` binding still
wins over a plugin. Only an adapter that `runs` a module may answer queries.

```ruby
runtime.registry.adapters["reference_plugin"].answered_queries  # => ["Calendar::Event.Occurrences"]
```

## runs

<!-- generated:begin word=runs -->
`runs runs` — fills `runs`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | runs |
<!-- generated:end -->

Names the wasm module a plugin runs, a file beside its `.adapter` (never a path out of that
directory). The module is a WASI command: it reads one question as JSON on stdin,
`{"question": "Calendar::Event.Occurrences", "args": {...}}`, and writes one answer as JSON on
stdout, `{"rows": [...]}` or `{"refused": "why"}`. An argument declared with `reference_to`
arrives as the state of the record it names, so the plugin never reaches the store. The module
gets no files, network, environment or arguments: it answers from its question alone, so the
same question always gets the same answer (the Ruby runtime also fixes its clock and randomness).
The Ruby runtime and the Rust host run the same module; the IR carries it to the host, so every
deploy that ships the IR ships the plugin. Ruby compiles it at boot, so a missing or broken
module stops the boot, not the first question. Running one on Ruby needs the `wasmtime` gem.

```ruby
runtime.registry.adapters["reference_plugin"].runs  # => "occurrences.wasm"
```

## provides

<!-- generated:begin word=provides -->
`provides provides` — fills `provides`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | provides |
<!-- generated:end -->

Names one thing this adapter can do beyond its port's contract, as a snake-case capability, called
once per capability. A caller asks before relying on it: `registry.adapter_provides?(domain,
aggregate, "set_transform")` answers for the adapter that aggregate is bound to, and is false for
an adapter that never says so. The Postgres, Sqlite and PostgresEra persistence adapters provide
`set_transform`, rewriting every row of an aggregate in one statement; Memory and Heki provide
nothing, so a caller works record by record there. A bulk run is the caller that asks: on Sqlite
and Postgres it compiles to one `UPDATE … RETURNING` when its command allows it (ADR 0129).
PostgresEra declares the capability but keeps its rows in one document, so its runs still go row
by row.

```ruby
runtime.registry.adapters["reference_sql"].capabilities  # => ["set_transform"]
```

