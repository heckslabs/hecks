# World

<!-- generated:begin id=page -->
Words available inside `world do ... end`.

*The tables on this page are generated from the language's own
aggregate-local syntax tables (`lib/hecks/language/**/*.bluebook`)
by `hecks project_reference` — do not edit inside the markers. The prose
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
# A persistence adapter that takes a `database`, declared only so
# `default_database` below has one to reach — a real project names
# Postgres, PostgresEra or SqlitePersistence.
Hecks.adapter("ReferenceStore") do
  port  "persistence"
  field :database
end

Hecks.hecksagon("WorldReference") { WorldReference::Beacon.persisted_by("Memory") }
Hecks.hecksagon("WorldReferenceUnpinned") { WorldReferenceUnpinned::Lamp.persisted_by("Memory") }

Hecks.world("WorldReference") do
  realm "Examples"
  latest "2"
  default_adapter "Memory"
  default_database "data/beacons"
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
WorldReference::Beacon.light!(callsign: { value: "w-1" }).callsign.value  # => "w-1"
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

## default_database

<!-- generated:begin word=default_database -->
`default_database default_database` — fills `default_database`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | default_database |
<!-- generated:end -->

Names the database connection every chapter's persistence adapter uses, once, instead of one `persisted_by("Adapter") do database ... end` block per chapter and per adapter. A project that attaches a dozen chapters otherwise repeats the identical block in a world per chapter — and twice each when an environment swaps one adapter for another, since the world cannot know which one the environment binds.

The default reaches a bind only when three things hold: it is a `persisted_by` bind, its adapter declares a `database` field (`Memory` and `Heki` do not, a projection adapter is never touched), and the chapter's own settings for that adapter name no `database`. Every other setting a chapter declares rides along unchanged. "Takes a `database`" is all the word looks at, so a file-backed adapter such as `SqlitePersistence` receives the default too; an environment that binds one names its own value in an `environments/<name>.world` overlay, which replaces the default for that environment. It is read from the chapter's own world first, then from the project's world — the world of the first chapter the boot loaded.

The resolution order, most specific first:

1. the chapter's own `persisted_by("Adapter") do database ... end` block;
2. `default_database` in the chapter's own world;
3. `default_database` in the project's world;
4. nothing — a world that declares no default behaves exactly as it did before the word existed.

The resolved settings are what the adapter is built from, identical to spelling the block out per chapter. `Registry#binding_settings` answers them:

```ruby
runtime.registry.binding_settings("WorldReference", "persisted_by", "ReferenceStore")
# => {adapter: "ReferenceStore", database: "data/beacons"}
```

A second chapter with no world of its own inherits the project's default:

```ruby
runtime.registry.binding_settings("WorldReferenceUnpinned", "persisted_by", "ReferenceStore")
# => {adapter: "ReferenceStore", database: "data/beacons"}
```

An adapter with no `database` field gets nothing added:

```ruby
runtime.registry.binding_settings("WorldReference", "persisted_by", "Memory")  # => {}
```

## default_adapter

<!-- generated:begin word=default_adapter -->
`default_adapter default_adapter` — fills `default_adapter`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | default_adapter |
<!-- generated:end -->

Names the persistence adapter every aggregate binds to, once, instead of one `persisted_by("Adapter")` line per aggregate in a hecksagon per chapter. It stands in wherever a chapter's hecksagon binds nothing for an aggregate — and for a chapter with no hecksagon at all, in place of the framework's in-memory fallback.

The resolution order, most specific first:

1. the aggregate's own bind in its chapter's hecksagon;
2. the chapter's domain-level default bind (`persisted_by "Adapter"`, bare);
3. `default_adapter` in the chapter's own world;
4. `default_adapter` in the project's world — the world of the first chapter the boot loaded;
5. the framework's in-memory adapter, for a chapter with no hecksagon; a hecksagon that leaves an aggregate unbound still refuses boot when no world declares a default.

The named adapter must be a persistence adapter; boot refuses one that is unknown, has no implementation, or answers a different port. A world may declare one default adapter; an `environments/<name>.world` overlay replaces it for that environment, so a base world can name the durable adapter while a local environment names a lighter one.

`default_adapter` and `default_database` pair naturally: the adapter says where every aggregate lives, the database says how to reach it. The project's world above names both. `WorldReferenceUnpinned` has a world of its own that names neither, so it inherits the project's:

```ruby
runtime.registry.default_adapter_for("WorldReference")         # => "Memory"
runtime.registry.default_adapter_for("WorldReferenceUnpinned") # => "Memory"
```

