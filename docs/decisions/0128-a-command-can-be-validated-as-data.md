# A command can be validated as data

**Status:** Accepted. Built on this branch, not released. Date: 2026-10-24.

## Context

`Dispatcher#dry_run?` answers "would this command be accepted?" by running the whole
pipeline in memory and raising the first refusal. That is enough to say yes or no to one
caller. A form, an agent or another service needs more: every reason the command would be
refused, each against the field it is about, and which rule said it. A refusal also had no
home for its kind or stage except a `def` in each class, and a rule that refused carried
only its message.

## Decision

1. **`Dispatcher#validate(verb, **args)` returns a `Validation`**: `ok?`, and `refusals`,
   the `Hecks::Refused` objects in the order dispatch would have found them. `to_h` is the
   shape every client receives: `{ok:, refusals: [{kind, stage, attribute, path, rule,
   message}]}`. `dry_run?` is unchanged: it still raises the first refusal, and the Rust
   conformance corpus still compares only `{verb, ok}` of it.
2. **A refusal is classed by a table of the language.** `RefusalClass` rows in the
   Vocabulary give each domain refusal its `kind` (`refused`, `not_found`, `unauthorized`,
   `absent_argument`) and its `stage`; `Hecks::Refused#kind` and `#stage` read them. A raise
   site may name a narrower stage (a reference that does not resolve is a `NotFound` in the
   `references` stage). A rule that refuses (a `given`, an `ensures`, an invariant) carries
   its description as `#rule`, and `#path` is a JSON Pointer to the offending value, the
   location format JSON Schema validators report.
3. **Stages are data.** `StepStage` rows give each dispatch step its stage. A validation
   runs the steps in order, finishes the stage that first refused, and stops: a later stage
   reads what an earlier one settled, so its answer would mean nothing.
4. **Within a stage, every check reports.** Unknown and absent arguments are one refusal
   per argument, each argument is coerced on its own, and every unmet `given`, `ensures`
   and invariant and every reference that does not resolve is recorded. A rule calls
   `Collecting.refuse`, which raises when nothing is collecting (so dispatch and `dry_run?`
   behave as before) and records when `validate` is.
5. **The role is checked first and alone.** A caller who may not run the command is told
   only that, not which arguments or rules it has.
6. **A validation is advisory.** The state it read can change before the real dispatch,
   which stays authoritative.

## Alternatives considered

- **Collect inside `dry_run?`.** Rejected: it would change what the conformance corpus
  compares and what every existing caller of `dry_run?` relies on.
- **Hand-written `kind` and `stage` in Ruby.** Rejected: the Rust kernel and the clients
  would then each keep their own copy. The table is the one place the language says it.
- **Run every stage regardless.** Rejected: ensures and invariants read the state a
  mutation produced from arguments that never passed, so their refusals would be noise.

## Consequences

- A field refused inside a value object is about the command's attribute and reports the
  path to the field (`/balance/cents`); only the first field refused inside one value
  object is reported.
- The lifecycle `from:` check is its own stage after the givens, so it is not reported
  alongside an unmet `given`.
- The Rust host answers the same envelope for `"dry_run": true` in its body protocol, from the
  kernel's own `dry_run` step (run on the journal's history and rolled back, with no reaction
  delivered or logged), and `hecks-client` has `validate()`. The kernel keeps every unmet given,
  ensure and invariant of the stage it stops in, and every unknown and absent argument, through a
  collector a real dispatch never binds, so the host reports them all with their `kind` and
  `stage` from the same `RefusalClass` table, an argument refusal naming its attribute and path
  and a rule refusal its rule. A coercion mismatch, a role or a lifecycle refusal stands alone.
  The console API and web routes take `?dry_run=1`.
- The neutral conformance corpus has a `validate` step beside `dry_run`: it records `{verb, ok,
  refusals}` with each refusal's class, kind, stage, attribute, path, rule and message, frozen in
  `expect.validations` (a fixture without the step omits the key). Ruby and Rust are each held
  to it, so a fixture may only ask what both engines list in full.
