# A change is previewed, confirmed against its plan, then applied

**Status:** Proposed. Built: the `Change` framework chapter (`lib/hecks/framework/bluebook/change.bluebook`, `change.hecksagon`, `change.behaviors`), the `Script` port, and the in-process `ScriptRunner` adapter. Not built: typed arguments per script, a `describe` ask, other adapters, and moving any existing `*Run` aggregate onto it. Date: 2026-10-17.

## Context

The Codebase and Custodian chapters model each maintainer task as its own aggregate (`LanguageRun`, `StyleRun`, `PublishingRun`, and others). They share one lifecycle (requested, examined, accepted, performed, completed or faulted) and one port shape (`SourceTree`, with `Examine` and `Perform`), but each repeats both, and several carry long lists of optional arguments (`LanguageRun` alone has about twenty). A run that changes something has a `confirm` switch on the request instead of a confirmation of a particular plan, so what a person agreed to and what runs are two separate facts. Custodian's `Operation` is the same pattern again, with a `script` field and more arguments.

## Decision

1. **The lifecycle is a chapter.** `Change` is a framework chapter, attached like Governance. Its one aggregate moves `requested`, `planned`, `confirmed`, `applied`, or `faulted`. It holds how any change moves and names no script. This is the bluebook side.
2. **A change is applied only against the plan that was shown.** Planning records the plan and a digest of the script, its arguments and its plan. `Confirm` names a digest and is refused unless it is the one planned. `Perform` plans again and refuses unless the digest still matches, so a plan that moved between confirming and applying faults the change instead of running.
3. **What a script does is behind a port.** The `Script` port has two asks, `Examine` (plan) and `Perform` (apply), answered by an adapter. `ScriptRunner` runs scripts registered with it in this process; a shell, a remote or a Rust adapter would implement the same two asks. This is the hecksagon side. Persistence defaults to Memory.
4. **No compensation.** A published artifact cannot be unpublished, so a failed apply faults the change with the script's message, and recovery is to request it again, as the release runner already resumes.
5. **Cheap, idempotent operations stay plain commands.** Running a spec does not need a plan.

## Consequences

- A script is a registration with a name, a `plan` and an `apply`, not a new aggregate and not new vocabulary.
- The existing `*Run` aggregates are untouched. Moving one over (the language chapter first, where the optional arguments are worst) is a later change that needs typed arguments per script, so the CLI and MCP door can still project them.
- Whether anyone reads the journal of changes is the open question: if not, the lifecycle is overhead for those tasks.
- `ScriptRunner` holds its scripts in a process-wide registry, which is right for a prototype and for a booted host, and wrong for two domains in one process that want different scripts under one name.
