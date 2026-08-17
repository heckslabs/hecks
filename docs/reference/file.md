# File

<!-- generated:begin id=page -->
Words available at the top of a file.

*The tables on this page are generated from the language's own
Syntax chapter (`lib/hecksagain/language/bluebook/syntax.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*
<!-- generated:end -->

These three words open the three kinds of file a domain is written
across, so the page declares one small domain in all three — what it
is, how this deployment stores it, and what values that deployment
needs:

```ruby bluebook
Hecks.bluebook "FileReference" do
  vision "One domain, written across the three kinds of file."

  aggregate "Dispatch" do
    attribute :docket, Docket

    identified_by :docket
    attribute :note, Note

    value_object("Docket") { attribute :value, String }
    value_object("Note")   { attribute :text,  String }

    # NOT `command "Raise"` — the door would be spelled
    # `Dispatch.raise`, and `raise` is Kernel's. Domain vocabulary is
    # worth choosing so it does not land on a built-in; banking renamed
    # its own `Freeze` and `Send` for the same reason.
    command "RaiseDispatch" do
      sets :docket
      sets :note
      emits "DispatchRaised"
    end
  end
end
```

```ruby boot
Hecks.hecksagon("FileReference") do
  FileReference::Dispatch.persisted_by("Memory")
end

Hecks.world("FileReference") do
  realm "Examples"
end

Hecks.port("dispatch_door") do
  verb   "persisted_by"
  signal :reply
end
```

## bluebook

<!-- generated:begin word=bluebook -->
`bluebook name, version: do ... end` — opens a `Bluebook` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
| `version:` | text | false | version |
<!-- generated:end -->

Opens a `.bluebook` file — one domain's aggregates, value objects, and rules, described as data. `version:` pins a contract version to the whole chapter; most domains declare none, and an unversioned chapter is always the "current" one for its name. A chapter may be split across several files that all open `Hecks.bluebook "Name" do ... end` — their declarations accumulate into one domain rather than the last file replacing the first.

What a chapter holds is readable back off the registry, and it is only
shape — no adapter, no realm, nothing about where it runs:

```ruby
runtime.registry.bluebook("FileReference").vision  # => "One domain, written across the three kinds of file."
runtime.registry.bluebook("FileReference").aggregates.map(&:hecks_name)  # => ["Dispatch"]
```

That is enough to dispatch against:

```ruby
FileReference::Dispatch.raise_dispatch!(docket: { value: "d-1" }, note: { text: "first" }).note.text  # => "first"
```

## hecksagon

<!-- generated:begin word=hecksagon -->
`hecksagon domain do ... end` — opens a `Hecksagon` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | domain |
<!-- generated:end -->

Opens a `.hecksagon` file — how THIS deployment wires an already-declared bluebook: which adapter persists each aggregate, which events it takes from outside, which driving ports it exposes. Says WHERE, never WHAT; see the Hecksagon reference page for the vocabulary inside.

The bind lives here, not in the chapter — `Dispatch` never says how it
is stored, and the same chapter would run on Postgres by changing this
file alone:

```ruby
runtime.registry.hecksagon("FileReference").binds.map(&:adapter)  # => ["Memory"]
```

## world

<!-- generated:begin word=world -->
`world domain do ... end` — opens a `World` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | domain |
<!-- generated:end -->

Opens a `.world` file — the values THIS deployment's adapter bindings actually need (a realm, an optional pinned `latest` version, and per-binding settings like a database URL). A sibling of the bluebook, never part of it: the same domain runs in many worlds. See the World reference page.

The realm is the deployment's own name for this running copy, and it is
the third file's business alone:

```ruby
runtime.registry.world("FileReference").realm  # => "Examples"
```

## port

<!-- generated:begin word=port -->
`port name do ... end` — opens a `Port` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
<!-- generated:end -->

Opens a `.port` file — a resource door a domain's own aggregates call by verb (`persisted_by`, `posted_by`, ...), bound to a real driven adapter at the world level. A sibling artifact too, reused across every domain that needs the same kind of door: `persistence`, `extraction`, and every other port under `lib/hecksagain/ports/` are real examples. See the Port reference page for the words inside.

Read back off the registry, the same way a world is:

```ruby
runtime.registry.ports["dispatch_door"].verb  # => "persisted_by"
```

