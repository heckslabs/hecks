# World

<!-- generated:begin id=page -->
Words available inside `world do ... end`.

*The tables on this page are generated from the language's own
Syntax chapter (`lib/hecksagain/language/bluebook/syntax.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*
<!-- generated:end -->

A `.world` is the only file here that carries no domain shape at all, so
these examples declare a small chapter and then two different worlds for
it — the same domain, wired twice:

```ruby bluebook
Hecks.bluebook "WorldReference", version: "2" do
  vision "A chapter that pins a contract version, so a world has something to pin to."

  aggregate "Beacon" do
    attribute :callsign, Callsign

    identified_by :callsign
    value_object("Callsign") { attribute :value, String }

    command "Light" do
      attribute :callsign, Callsign
      sets :callsign
      emits "BeaconLit"
    end
  end
end
```

```ruby bluebook
Hecks.bluebook "WorldReferenceUnpinned" do
  vision "The ordinary case: no version, so no pin to disagree with."

  aggregate "Lamp" do
    attribute :callsign, Callsign

    identified_by :callsign
    value_object("Callsign") { attribute :value, String }

    command "Light" do
      attribute :callsign, Callsign
      sets :callsign
      emits "LampLit"
    end
  end
end
```

A `.world` is a DECLARATION, the same as a bluebook or a hecksagon — it
is read while the registry is being built and cannot be written from
ordinary calling code, so both of these live in the boot below rather
than in an example further down:

```ruby boot
Hecks.hecksagon("WorldReference") { WorldReference::Beacon.persisted_by("Memory") }
Hecks.hecksagon("WorldReferenceUnpinned") { WorldReferenceUnpinned::Lamp.persisted_by("Memory") }

Hecks.world("WorldReference") do
  realm "Examples"
  latest "2"
end

Hecks.world("WorldReferenceUnpinned") do
  realm "Examples"
end
```

## realm

<!-- generated:begin word=realm -->
`realm realm` — fills `realm`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | realm |
<!-- generated:end -->

Deployment identity — free text, not a closed set (`"RiveGauche"`, `"Examples"`). It is what makes a command or query's FQN addressable (`Realm::Domain::Aggregate.verb`), and `ProjectRegister` refuses to boot a project whose world has no realm, even though the meta-domain's own `Declare` command marks the field optional.

The realm is read back off the registry, not off the bluebook — the
chapter itself never mentions one:

```ruby
runtime.registry.world("WorldReference").realm  # => "Examples"
```

It is deployment identity, so it addresses rather than describes.
Nothing about `Beacon` changes when the realm does:

```ruby
WorldReference::Beacon.light(callsign: { value: "w-1" }).callsign.value  # => "w-1"
```

## latest

<!-- generated:begin word=latest -->
`latest latest` — fills `latest`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | latest |
<!-- generated:end -->

Pins which `version:` of the bluebook this world treats as current — an unversioned FQN resolves to whichever version matches `latest`. Optional (a domain with no `version:` needs none), but if it names a version that disagrees with the bluebook's own, the project refuses to boot with `LatestMismatch` rather than silently picking one. None of the examples in this repository set it; every worked domain here is unversioned.

The chapter above is declared `version: "2"`, and this world pins the
same:

```ruby
runtime.registry.bluebook("WorldReference").version  # => "2"
runtime.registry.world("WorldReference").latest      # => "2"
```

A world may leave it off entirely — an unversioned chapter needs no pin,
and `latest` answers `nil` rather than guessing:

```ruby
runtime.registry.bluebook("WorldReferenceUnpinned").version  # => nil
runtime.registry.world("WorldReferenceUnpinned").latest      # => nil
```

