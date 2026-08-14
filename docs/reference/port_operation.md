# PortOperation

<!-- generated:begin id=page -->
Words available inside `operation do ... end` / `tells do ... end` / `asks do ... end`.

*The tables on this page are generated from the language's own
Syntax chapter (`lib/hecksagain/language/bluebook/syntax.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*
<!-- generated:end -->

A port operation is the only place these five words appear together, and
`answers`/`refuses` appear nowhere in the corpus at all, so the page
declares a domain of its own — a licence that is told when an inspection
happened, and asks a registry whether it is still valid:

```ruby bluebook
Hecks.bluebook "PortOperationReference" do
  vision "One licence, told things by the outside and asking things of it."

  aggregate "Licence" do
    identified_by Serial, as: :serial
    attribute :holder, Holder

    value_object("Serial") { attribute :value, String }
    value_object("Holder") { attribute :value, String }

    command "Grant" do
      attribute :serial, Serial
      attribute :holder, Holder
      then_set :serial, to: :serial
      then_set :holder, to: :holder
      emits "LicenceGranted"
    end
  end
end
```

```ruby boot
class RefRegistry
  def check(**args)
    raise "registry has no record of that licence" if args[:serial].to_s.include?("unknown")

    { "standing" => { "value" => "valid" } }
  end

  # A PORT THAT HAS NOTHING TO SPREAD — one unnamed value, not a record.
  def locate(**) = "https://registry.example/lic-1"
end

Hecksagain::Adapters.const_set(:RefRegistry, RefRegistry) unless Hecksagain::Adapters.const_defined?(:RefRegistry, false)
Hecks.adapter("RefRegistry") { port "Registry" }

Hecks.hecksagon("PortOperationReference") do
  PortOperationReference::Licence.persisted_by("Memory")

  PortOperationReference::Licence.port "Registry" do
    tells "Inspected" do
      reference_to Licence, as: :serial
      attribute :inspector, Holder
      emits "InspectionRecorded"
    end

    asks "Check" do
      reference_to Licence, as: :serial
      answers "StandingReturned"
      refuses "StandingUnavailable"
    end

    asks "Locate" do
      reference_to Licence, as: :serial
      answers "LocationReturned"
      refuses "LocationUnavailable"
    end
  end
end
```

```ruby
runtime.dispatch("PortOperationReference::Licence.Grant", serial: { value: "lic-1" }, holder: { value: "Ada" })
runtime.dispatch("PortOperationReference::Licence.Grant", serial: { value: "lic-unknown" }, holder: { value: "Bee" })
```

## reference_to

<!-- generated:begin word=reference_to -->
`reference_to type, as:` — fills `attributes`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | constant | true | type |
| `as:` | symbol | false | name |
<!-- generated:end -->

The record this operation's external fact is about; `as:` picks the
argument name, so the port's payload can key-match the command a
policy will later forward it to.

`as: :serial` is what makes the operation addressable by the licence's
own identity — the external caller names the thing in the domain's own
terms, not with an id the domain minted:

```ruby
told = runtime.dispatch("PortOperationReference::Licence.Registry.Inspected", serial: "lic-1", inspector: { value: "Grace" })
told.events.first.payload[:serial]  # => "lic-1"
```

## attribute

<!-- generated:begin word=attribute -->
`attribute name, type, type, default:, optional:, pattern:, admits:` — fills `attributes`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | name |
| positional 2 | constant | false | type |
| positional 2 | text | false | type |
| `default:` | literal | false | default |
| `optional:` | flag | false | optional |
| `pattern:` | text | false | pattern |
| `admits:` | text | false | admits |
<!-- generated:end -->

An extra field the external fact carries, declared the same way a
command's own `attribute` is.

`inspector` is the fact's own detail, and it rides through onto the
event unchanged — no `then_set` anywhere, because an operation stores
nothing:

```ruby
told.events.first.payload[:inspector][:value]  # => "Grace"
```

The same gate a command's arguments meet applies here — a field the
operation never declared is refused rather than carried along:

```ruby
runtime.dispatch("PortOperationReference::Licence.Registry.Inspected", serial: "lic-1", weather: "fine")  # ~> UnknownArgument: weather
```

## emits

<!-- generated:begin word=emits -->
`emits emits` — fills `emits`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | emits |
<!-- generated:end -->

The event this operation announces once called. `reference_to`,
`attribute`, and `emits` are the whole of what a driving port's
operation may declare — no `given`, no `then_set`; it translates an
external fact into the domain's own event vocabulary and stops there
(see wiring.md).

One event, and the record itself is untouched — `Inspected` announced
something without changing the licence at all:

```ruby
told.events.map(&:name)  # => ["InspectionRecorded"]
PortOperationReference::Licence.find("lic-1").holder.value  # => "Ada"
```

## answers

<!-- generated:begin word=answers -->
`answers answers` — fills `answers`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | answers |
<!-- generated:end -->

The event an `asks` becomes when the adapter came back — carrying what it
returned alongside the arguments the ask was made with.

A Hash answer is SPREAD, not nested: the adapter's own keys become
top-level fields on the event. That is what closes the loop, because a
policy re-enters its target with the event payload verbatim and cannot
reach inside a key — an answer tucked under one could be read by a human
and by nothing else. It is a real contract on the adapter, which must
return what the reacting command takes, in the shape the runtime coerces
(`{ number: { value: 43 } }`, not `43`).

Singular, where `emits` is a list: an ask has exactly one success. A call
that could succeed two different ways is two calls.

Refused on a `tells`, which has no channel back to its caller.

What the adapter returned arrives under `answered`, beside the
arguments the ask was made with:

```ruby
asked = runtime.dispatch("PortOperationReference::Licence.Registry.Check", serial: "lic-1")
asked.events.map(&:name)  # => ["StandingReturned"]
asked.events.first.payload[:standing][:value]  # => "valid"
```

The ask's own arguments are still there beside it, which is how the
event says WHICH licence this standing belongs to:

```ruby
asked.events.first.payload[:serial]  # => "lic-1"
```

Only an answer with no names of its own keeps the nested shape — a port
returning a bare string has nothing to spread, and `answered:` is the
honest word for one unnamed value:

```ruby
located = runtime.dispatch("PortOperationReference::Licence.Registry.Locate", serial: "lic-1")
located.events.first.payload[:answered]  # => "https://registry.example/lic-1"
```

## refuses

<!-- generated:begin word=refuses -->
`refuses refuses` — fills `refuses`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | refuses |
<!-- generated:end -->

The event an `asks` becomes when the outside said no — carrying what it said
under `refusal`.

EVERY failure lands here, deliberately: a timeout, a bad credential, a
missing adapter, a nil where a number was wanted. A raise from the far side
of a boundary is not an exception in this domain's terms, it is the outside
refusing, and the chapter has already named the word for that. So an ask
never propagates — the command that triggered it stands, and a `policy`
reacting to this event is where a retry or a give-up lives (see banking's
`ScheduledPayment`, whose `attempts` counter and `Retry` command are the
worked example of exactly that shape).

Required on every `asks`. An ask that cannot fail is a call into a system
you do not control, pretending otherwise.

The adapter raises, and the caller gets an event rather than an
exception — the dispatch returns normally:

```ruby
refused = runtime.dispatch("PortOperationReference::Licence.Registry.Check", serial: "lic-unknown")
refused.events.map(&:name)  # => ["StandingUnavailable"]
refused.events.first.payload[:refusal][:value]  # => "RuntimeError: registry has no record of that licence"
```

"EVERY failure lands here" includes failures that are not the outside
world's fault at all — a broken adapter refuses exactly the same way a
reachable one saying no does, which is the point: the domain has one
word for "this did not happen", and it is in the record.

