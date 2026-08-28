# Port

<!-- generated:begin id=page -->
Words available inside `port do ... end`.

*The tables on this page are generated from the language's own
aggregate-local syntax tables (`lib/hecks/language/**/*.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*
<!-- generated:end -->

Ports are declared for real, not invented for this page — `persistence`
and `extraction`, the two every domain needs, are the working examples:

```ruby boot
Hecks.port("reference_persistence") do
  verb    "persisted_by"
  signal  :reply
  answers :find_by_id
end
```

## verb

<!-- generated:begin word=verb -->
`verb verb` — fills `verb`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | verb |
<!-- generated:end -->

The how-verb an aggregate calls this port by (`persisted_by`, `extracted_by`, `posted_by`, ...) — free text, not a closed set, since a domain names whichever verb reads best for what the port does. Optional to declare at all: omitting it still opens a real port, just one no aggregate can call yet.

```ruby
runtime.registry.ports["reference_persistence"].verb  # => "persisted_by"
```

## signal

<!-- generated:begin word=signal -->
`signal signal` — fills `signal`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | signal |
<!-- generated:end -->

Whether calling this port answers with a value (`:reply`) or fires an effect with nothing to hand back (`:effect`). Defaults to `:reply` when never declared — most ports (persistence, extraction) answer something back; an effect port is the exception, spelled out rather than assumed.

```ruby
runtime.registry.ports["reference_persistence"].signal  # => :reply
```

## answers

<!-- generated:begin word=answers -->
`answers answers` — fills `answers`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | answers |
<!-- generated:end -->

The method contract — the name of a method a real adapter for this port must `respond_to?`. Repeatable: call `answers` once per method a caller will actually dispatch to (`clock`'s own real declaration is `answers :now`). Optional to declare at all, the same way `verb` is; a port with none is exactly today's pre-existing behavior, unchecked by `verify!` past the existing adapter/verb/settings gates. Declared, an adapter bound to this port that does not respond to every named method fails at boot with a `WiringError` naming the adapter and the missing method, instead of a bare `NoMethodError` the first time a live dispatch actually needed it.

```ruby
runtime.registry.ports["reference_persistence"].answers  # => [:find_by_id]
```

