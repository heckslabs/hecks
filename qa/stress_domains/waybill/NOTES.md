# `Waybill` — retention note

**Kept.** A construct combination that, checked directly against every
existing `process_manager` in the corpus before this domain was
authored, had never once been declared: a saga leg whose own `dispatch`
targets a command owned by a NESTED ENTITY, not a plain aggregate.

## What was checked before authoring this

- `examples/banking/bluebook/new_customer_onboarding.bluebook`'s own
  `Onboarding`, `examples/banking/bluebook/transfers_and_payments.
  bluebook`'s own `Settlement`/`ExternalSettlement`, and `qa/bluebook/
  quality_control.bluebook`'s own `BugCiWatch` — every `dispatch` in
  every one of them targets a plain aggregate command
  (`Account::Debit`, `Manifest::Open`-shaped references, `Bug::Regress`).
  None targets an entity.
- `qa/stress_domains/nested_pieces` proves a two-level nested entity
  fuzzes and dispatches correctly through ORDINARY (non-saga) addressing
  — but nothing in that domain declares a `process_manager` at all.
- No existing corpus member combines the two: a saga driving dispatch
  into a nested entity's own command.

## What this domain found, first real run

The combination does not work. `SagaInterpreter#qualified` (`lib/hecks/
runtime/saga_interpreter.rb`) decides whether a dispatch's own
`command_name` already carries an explicit domain qualifier with one
heuristic:

```ruby
def qualified(command_name, domain)
  command_name.include?("::") ? command_name : "#{domain}::#{command_name}"
end
```

That heuristic is correct for a plain aggregate command (`dispatch
Account::Debit` — `Naming.command_ref` rewrites its one `::` to `.`,
leaving none, correctly triggering domain-prefixing) and for a
genuinely cross-domain one (`dispatch Banking::Account::Debit` — one
`::` survives the rewrite, correctly read as already-qualified) — but a
bare, SAME-DOMAIN entity command reference (`dispatch Manifest::Slot::
Fill`) ALSO has exactly one `::` left after the identical rewrite
(`Naming.command_ref` only ever strips the LAST `::`), for a completely
different reason: entity nesting, not a domain qualifier. `qualified`
cannot tell the two apart from the string alone, and picks the
cross-domain reading — so the runtime dispatch call gets
`"Manifest::Slot.Fill"`, never prefixed with the chapter's own name at
all, and `Naming.split_verb` then reads "Manifest" as the DOMAIN and
"Slot" as the AGGREGATE — a domain that (almost always) does not exist.
`ReactionInvocation.resolve_target` raises `UnknownVerb` ("reaction
target \"Manifest::Slot.Fill\" does not resolve to an aggregate"), which
`SagaInterpreter#deliver_saga_dispatch` — correctly, by its own lights —
treats as an ordinary DOMAIN REFUSAL (`errors.rb`'s own comment:
"UnknownVerb IS one of these, and deliberately"), so the leg silently
"refuses" every single time, structurally — not data-dependent, not
fuzz-luck-dependent. `spec/waybill_spec.rb`'s three examples confirm
this directly: `Manifest.Open`/`Manifest.AddSlot` (aggregate-level, legs
1-2) deliver correctly every time; `Manifest::Slot.Fill` (entity-level,
leg 3) never delivers; the saga's own `:refused` leg fires every time as
a result, making `ConsignmentShipped` (this process manager's own
`ends_on`) an unreachable happy path today.

## Confirmed NOT a saga-wide bug — `PolicyInterpreter` does not share it

`PolicyInterpreter#deliver` builds its own dispatch target differently:

```ruby
target = "#{policy.target_domain || domain}::#{policy.trigger_command}"
```

Unconditional — no heuristic, no ambiguity — because a policy's own
cross-domain qualifier is carried in a SEPARATE `target_domain:` field,
never inferred from the command reference string at all. A policy
`trigger`-ing the identical entity command works correctly today
(confirmed by reading `resolve_target`, which fully supports entity
addressing via `Target#entities` — the routing logic is right; only
`SagaInterpreter#qualified`'s string heuristic feeding it is wrong).

## A documented sibling, not a first-of-its-kind

`lib/hecks/bluebook/model_check.rb`'s own `ALLOWED_FINDINGS["quality_
control"]` already names the SAME underlying shape once, for a
different builder: a policy's `trigger Ticket::IssueTracker::File` (a
three-segment aggregate/port/operation reference) hits `Naming.
command_ref`'s bare-constant rewrite the identical way, "not a shape
[it] was built for ... rewrites to 'Ticket::IssueTracker.File', which
parses as a totally different aggregate." That comment already named
this "belongs to Naming/PolicyBuilder — a real follow-up, not something
to force-fix here." This domain's own finding is the `SagaInterpreter`/
entity-command sibling of that exact same family — not a coincidence:
both are consequences of `Naming.command_ref`'s rewrite conflating "one
remaining `::` because of a genuine cross-domain qualifier" with "one
remaining `::` because of nesting" (entity, in this case; port
operation, in that one), and neither call site (`SagaInterpreter#
qualified`, the `quality_control` case's own trigger resolution) has
enough information to tell the two apart from the string alone.

## Not fixed here, on purpose

Same restraint this domain's own sibling, `nested_pieces`, already
exercised for BUG#4: this domain was authored from an isolated worktree
with no access to `qa/bluebook/quality_control.bluebook`'s own persisted
ledger, so the `Bug.log`/judgment/fix lifecycle belongs to the session
that DOES hold that ledger, not to this PR. `bin/model_check
qa/stress_domains/waybill` reports exactly one error
(`unknown_dispatch`, `Packing`, `Manifest::Slot.Fill`) and two harmless
`stuck_state` warnings (`Consignment`'s own terminal `shipped`/
`cancelled` states — expected, same shape banking's own terminal states
produce). The error is the finding itself, not a defect in this domain,
so `lib/hecks/bluebook/model_check.rb`'s own `ALLOWED_FINDINGS` was
deliberately left untouched rather than adding a `"waybill"` entry:
`qa/stress_domains/*` is not part of `bin/model_check`'s own default
sweep or `spec/model_check_spec.rb`'s `MODEL_CHECK_CORPUS` (neither
`ledger_ordering` nor `nested_pieces` is either — confirmed directly,
both come back clean with no allowlist of their own), and
`spec/model_check_spec.rb`'s own "names nothing in the allowlist that
the checker no longer finds" check has a documented sharp edge for
exactly this situation (that file's own comment on `MODEL_CHECK_QA_
MEMBERS`, about a `.fetch(name) { next }` that "only exits the fetch
block ... not the outer `each`" once already breaking silently the same
way) — adding an allowlist entry for a domain outside `MODEL_CHECK_
CORPUS` risks exactly that landmine for no CI benefit. Wiring `qa/
stress_domains/*` into `bin/model_check`'s default sweep and `spec/
model_check_spec.rb`'s own corpus (so all three stress domains get the
same CI discipline `examples/*` and `qa/bluebook/*` already have) is a
real, separate follow-up — bigger than this PR's own scope, and not
blocking it: `bin/model_check qa/stress_domains/waybill`, run directly,
already gives an honest, fully-explained account of the one finding.

## Suggested fix, for whoever picks this up

`SagaInterpreter#qualified` has `@registry` available (it is an
instance method); a check like "does the first segment already name a
registered domain?" (`@registry.bluebook(command_name.split('::').
first)`) would disambiguate correctly in both directions, the same way
`PolicyInterpreter` sidesteps the question entirely by never needing to
infer it from the string. Not attempted here — untouched runtime code
needs the ledger's own judgment call and real verification against
every existing saga in the corpus (`Onboarding`/`Settlement`/
`ExternalSettlement`/`BugCiWatch`), more than this domain's own
authoring scope.

## Fuzz status

`bin/fuzz qa/stress_domains/waybill --seeds 40 --steps 30` — clean, 0
property violations, 0 crashes. The entity-dispatch refusal is caught
and recorded as an ordinary domain refusal (not an exception), so
property-based fuzzing alone does not surface this finding — only the
hand-written `spec/waybill_spec.rb` does, the same way `nested_pieces`'
own hop-one/hop-two confirmations needed hand-written specs rather than
relying on the fuzzer to stumble into them. Rust-side confirmation not
attempted (`bin/project_rust qa/stress_domains/waybill` not run) — same
open item `ledger_ordering`/`nested_pieces` already carry, for the same
reason (authored Ruby-only, given the time already spent on this
domain's own investigation).
