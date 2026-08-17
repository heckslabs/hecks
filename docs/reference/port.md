# Port

<!-- generated:begin id=page -->
Words available inside `port do ... end`.

*The tables on this page are generated from the language's own
Syntax chapter (`lib/hecksagain/language/bluebook/syntax.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*
<!-- generated:end -->

Ports are declared for real, not invented for this page — `persistence`
and `extraction`, the two every domain needs, are the working examples:

```ruby boot
Hecks.port("reference_persistence") do
  verb   "persisted_by"
  signal :reply
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

