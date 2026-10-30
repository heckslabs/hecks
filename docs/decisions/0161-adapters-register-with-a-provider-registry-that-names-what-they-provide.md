# Adapters register with a provider registry that names what they provide

**Status:** Proposed.
Date: 2026-10-29.
Relates to: 0160 (eras as a capability), 0154 (kernel, adapter and projector).

## Context

An adapter reaches the runtime in three ways, and none of them is a registration:

- A class under `Hecks::Adapters` is found by name, through `Runtime::AdapterLookup`. An adapter
  outside that namespace cannot be found.
- `Ports::Loading.bootstrap_with` registers the one loading adapter that starts a boot.
- A hecksagon names an adapter (`persisted_by "PostgresEra"`), and boot checks the name against the
  classes it can see.

So an adapter package cannot ship on its own, and nothing records what an adapter provides. ADR
0160 needs that second part: the era gate should ask whether an adapter provides lineage, not
compare class names.

## Decision

1. **One registration point.** `Hecks::Ports::Providers.register(name, klass, provides:)` records
   an adapter under its `.adapter` name. A gem calls it when it loads. Core registers its own
   adapters the same way, so nothing is special-cased. It lives in `lib/hecks/ports/providers.rb`,
   beside `loading.rb`.
2. **Capabilities are named.** `provides:` is a list of capabilities from a closed set, declared in
   the bluebook vocabulary, not free text. The first set: `persistence`, `lineage`,
   `saga_store`, `outbox`, `read_model`, `loading`, `identity`, `clock`, `remote_dispatch`.
   Adding a capability is a bluebook change.
3. **Lookup goes through the registry.** `Providers.lookup(port_name)` returns the adapters that
   provide a port. `AdapterLookup` uses it and stops searching `Hecks::Adapters` by name. A
   hecksagon's `persisted_by` still names an adapter, and boot checks that the named adapter
   provides `persistence`.
4. **Boot checks the wiring.** Boot refuses, naming the port and the adapters it saw, when a
   hecksagon names a port nothing provides, when two adapters claim one port in one domain, or when
   a named adapter lacks the capability its port needs.
5. **Loading stays the same.** `Ports::Loading.bootstrap_with` becomes a registration with the
   `loading` capability. Its callers are unchanged.
6. **Era checks ask the registry.** ADR 0160's gate asks whether the bound adapter provides
   `lineage`.

## Consequences

- An adapter package (`hecks-sql`, later others) registers itself on load. Core does not name it.
- Adding an adapter no longer means editing `Hecks::Adapters` or the lookup.
- Capability lists are checked at boot, so a missing capability fails before the first command.
- Two adapters can be loaded side by side in one process, each providing different ports.

## Not decided here

- How a gem's `.adapter` file reaches the loader. Today a gem must be on the load path; the
  registration call is the first step, and discovery is a later one.
- Ordering when two adapters provide the same capability in one domain. This ADR refuses it; a
  later one may allow an explicit choice.

## Why not "bus"

A bus passes messages between parts at runtime. This is a directory: adapters say what they
provide, and boot looks them up. "Registry" alone would clash with `Runtime::Registry`, which
holds aggregates.
