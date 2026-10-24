# A refusal has one parent, and a handle names every verb

**Status:** Accepted. Built on this branch, not released. Date: 2026-10-24.

## Context

A driving adapter that turns a refusal into a user-facing message (a form, a web
controller, a CLI) has to rescue `*Hecks::Runtime::DOMAIN_REFUSALS`, a splatted list,
and has no way to tell which field a refusal is about except by parsing its text. Every
refusal class inherited straight from `StandardError`, so `rescue Hecks::Refused` was not
possible and the classes shared no reader.

`Handle` defined each non-creating verb as a bang singleton method (`freeze!`), but the
bare name (`freeze`, `send`, `open`) fell through to `Object`/`Kernel`. A caller who
wrote `account.freeze` got `Object#freeze`, silently: no dispatch, no refusal. The
design in `docs/rails-integration.md` gives the bare name a meaning, the verb's
`IR::Command`, so a form can read a verb's attributes from the record in hand.

## Decision

1. **`Hecks::Refused < StandardError` is the parent of every domain refusal.** Every class
   the `DomainRefusal` vocabulary rows name inherits from it, and nothing else does, so
   `rescue Hecks::Refused` and `rescue *Runtime::DOMAIN_REFUSALS` catch the same set.
   `DOMAIN_REFUSALS` stays read from the vocabulary; a spec holds the two in step.
   `StaleWrite`, `WiringError` and `PluginRefusal` stay outside: they are not domain
   refusals today, and the interpreters' retry and propagation rules depend on that.
2. **A refusal that knows its attribute exposes it as `#attribute`** (a Symbol, else nil):
   an argument that is unknown, absent or mistyped, and a stored field a read finds
   absent. A refusal that names several (two absent arguments) carries the first in
   sorted order, the same order its message lists them in. The message is unchanged.
3. **A handle defines both names for every non-creating verb at construction.** `name!`
   dispatches, as before; `name` answers the verb's `IR::Command`. Both are singleton
   methods, so they win over `Object`/`Kernel` methods of the same name.
4. **Readers and the handle's own methods keep their names.** A bare verb name is not
   defined when it is a field reader (an attribute, a reference accessor, the lifecycle
   field), a method `Handle` itself defines, or one of the few `Object` methods Ruby's
   own machinery calls (`class`, `hash`, `object_id`, `__send__`, `respond_to?`,
   `dup`, `clone` and the like). The bang form still dispatches in every case.

## Alternatives considered

- **Make `DOMAIN_REFUSALS` `[Hecks::Refused]`.** It would drop the vocabulary rows as the
  source of what counts as a refusal. Rejected: the rows stay the meaning, the class is
  the mechanism, and a spec checks they agree.
- **Raise on a verb whose bare name collides with a reader.** It would refuse chapters
  that boot today. Rejected: the reader keeps the name and the bang form is unaffected.

## Consequences

- `handle.send(:x)` on a record whose aggregate has a `Send` verb answers the verb's IR
  command; generic code calls `public_send` or `__send__`, as Ruby advises.
- The Rust kernel's `Refusal::kind` names are unchanged, so the conformance corpus and
  the host's refusal mapping still agree; Rust has no class hierarchy to change.
