# `Corrections` — retention note

**Kept.** Realizes ANGLE-9 (`ask backlog`, QualityControl ledger): `corrects`
(retroactive correction) had exactly one declaration anywhere in the corpus
(`examples/banking/bluebook/deposit_accounts.bluebook:353`, aggregate-level),
was absent from `Hecks::Fuzzing::Properties::FEATURE_COVERAGE`, and no
property anywhere checked it at all. This domain puts `corrects` on an
ENTITY-level command for the first time, adds the corpus's first
`list_of(ENTITY)` command argument, and a `remove:`-then-`append:` sequence
on the same entity list — and every one of the three found something real,
verified by hand, not merely asserted.

## 1. Entity-level `corrects` crashes Ruby outright — `Hecks::Runtime::WiringError`

`Ledger::Entry::Amend` (`corrects "EntryRecorded"`) cannot be dispatched at
all. Two independent gaps compound:

- **Build time:** `AggregateBuilder::Sealing#seal_correction_targets`
  (`lib/hecks/bluebook/dsl/aggregate_builder/sealing.rb:256`) walks only
  `@commands` — the aggregate's OWN top-level command list — never
  `@entities`. An entity's own `corrects` mutation is invisible to it, so
  the build-time "does anything actually emit this event" check silently
  never runs for `Amend` at all (it built cleanly here purely because
  `EntryRecorded` also happens to not need checking — nothing failed loudly,
  which is itself the problem: an entity `corrects` naming an event nothing
  emits would build just as cleanly).
- **Dispatch time:** `EntityInterpreter#step_enforce_givens`
  (`lib/hecks/runtime/entity_interpreter.rb:211-215`) never calls
  `CommandRules::Admissibility#enforce_correction_target` at all — only
  `CommandInterpreter`'s own aggregate-level twin
  (`command_interpreter.rb:132-146`) does. And `EntityElement.
  apply_to_element`'s own `case mutation.op`
  (`lib/hecks/runtime/entity_element.rb:220-253`) has no `:corrects` branch
  at all — unlike `MutationApplier#apply`'s aggregate-level twin
  (`command_interpreter/mutation_applier.rb:107-108`), which treats
  `:corrects` as a documented no-op. Reaching the `else` branch there raises:

  ```
  Hecks::Runtime::WiringError: no entity mutation applier handles :corrects
  — add one before declaring it
  ```

  This is NOT one of `Hecks::Runtime::DOMAIN_REFUSALS`, so it propagates
  straight through `Fuzzing::Replay`'s own per-step isolation and crashes
  the whole run — confirmed directly:

  ```
  $ bin/rust_conformance qa/stress_domains/corrections /tmp/corrections_amend.json
  .../entity_element.rb:252:in `apply_to_element': no entity mutation
  applier handles :corrects — add one before declaring it (Hecks::Runtime::WiringError)
  ```

  **Random-fuzz frequency, confirmed, not guessed:** running
  `SequenceGenerator.generate` + `Replay.call` directly (steps=25, seeds
  1-40) crashes Ruby on **8 of 40 seeds (20%)** — seeds 3, 12, 15, 24, 26,
  34, 36, 37 — every time the generator happens to construct a dispatch
  against an entry that actually exists. The other 32 seeds' own `Amend`
  attempts were refused earlier, at the payload gate (`UnknownArgument`/
  `AbsentArgument`) before ever reaching `apply_mutations` — the crash is
  data-dependent, not universal, which is exactly why it had never been
  seen before this domain existed to isolate it.

## 2. Rust's own generated code has NO admissibility check for entity-level `corrects` — the headline divergence

`rust/project/commands.rb#corrects_given_specs` (the synthetic, prepended
`GivenSpec` that makes ADR 0049's admissibility check real) is called ONLY
from `emit_command` (line 465, aggregate-level). `emit_entity_command`
(line 845) and `emit_nested_entity_command` never call it — confirmed by
reading the generated output directly (`rust/src/generated/corrections/
ledger.rs`, `dispatch_entity_entry_amend`): the `given_specs` array handed
to `crate::kernel::dispatch_entity` is empty, and the mutation closure only
ever applies `record.amount = args.amount.clone()` — no `emitted_*` flag
check, no flag-set line, nothing.

**Proven directly, not inferred from reading code alone** — three real
dispatches through the compiled `native` binary:

1. `Open` → `Record` (amount=500) → `Amend` (amount=700), same entry.
   Rust succeeds unconditionally: `EntryAmended` fires, `CorrectionWatch`
   runs its saga to completion (`AuditTrail` opens and flags), all in one
   `bin/rust_conformance ... native` call. Ruby cannot even attempt this —
   see finding 1.
2. `Open` (no `Record` at all) → `Amend` against a sequence that was NEVER
   created: Rust correctly answers `NotFound` — this is `EntityElement`'s
   own element-lookup refusal, unrelated to the corrects admissibility
   question, and it works fine on both engines.
3. **The real test, isolating the admissibility gap from the lookup
   check:** `Open` → `ReplaceEntries` (creates a `sequence=5` entry WITHOUT
   ever emitting `EntryRecorded` — see finding 3 below) → `Amend` against
   that same entry. Rust accepts it unconditionally — `EntryAmended` fires,
   the saga completes, `FlaggedTrailCount` would read 1 — even though
   `EntryRecorded` was **never emitted for this record, ever, in this
   history.** This is not a lookup gap; it is proof the correction
   guarantee `corrects` exists to provide (`NothingToCorrect` when the
   named event never happened) is completely absent from Rust's own
   generated code for an entity-level `corrects`, corpus-wide.

**Net effect:** on the one construct combination this domain exists to
test, Ruby and Rust do not merely disagree — Ruby cannot execute the verb
at all, and Rust executes it with none of the semantic guarantee the
keyword is supposed to provide. Neither engine can be directly differential-
compared on this verb as a result (there is no Ruby answer to diff
against); this write-up plus the three reproductions above is the finding.

## 3. `sets :entries, remove: :sequence` is a silent no-op against an entity-typed list — confirmed by hand

`Hecks::Runtime::Value::Coercion#for_attribute` (`lib/hecks/runtime/value/
coercion.rb:65-69`) routes ANY `list_of` attribute through
`#hydrate_entity_list` before ever checking whether the element type is an
entity or a value object. That method (`coercion.rb:416-430`)
unconditionally does `Array(value).map { ... }` — no `value.is_a?(Array)`
guard, unlike its own value-object sibling `#hydrate_value_object_list`
(`coercion.rb:459`), whose own comment explains exactly why that guard
exists for `remove:`'s single-target value: `Array(a_Hash)` is NOT
harmless (`Array()` opens a bare Hash into its own pairs), so the
value-object branch deliberately checks `value.is_a?(Array)` first. The
entity branch has no such check. For `Void`'s scalar `EntrySequence`
target, `Array(value)` just wraps it into a one-element Array instead of
shredding a Hash — and `MutationApplier#removed`'s own
`Array(instance[target]).reject { |element| element == value }` then
compares each stored Hash element against that wrapping Array, which can
never be `==` a Hash. **Nothing is ever removed, and nothing refuses
either** — `Void` dispatches, succeeds, emits `EntryVoided`, and changes
nothing.

Confirmed by hand, via direct Ruby dispatch (not fuzzed — a deliberate,
scripted sequence):

```
Record(amount=500) -> entries: [{sequence: 1, amount: 500}]
Record(amount=200) -> entries: [{sequence: 1, ...}, {sequence: 2, amount: 200}]
Void(sequence=2)    -> entries: [{sequence: 1, ...}, {sequence: 2, ...}]   # UNCHANGED
Record(amount=999)  -> entries: [..., ..., {sequence: 3, amount: 999}]    # minted 3, not 2
```

Also confirmed structurally, independent of the runtime bug: `bin/
project_rust` refuses to generate `Void` at all —
`skipping Corrections::Ledger.Void: sets op(s) remove not generated yet
(only append/set/increment/decrement/multiply/clamp/delegate/corrects
are)` — so `remove:` on an entity list is a full **structural** gap on the
Rust side (the verb does not exist there), on top of being a silent no-op
on the Ruby side. Confirmed live in a generated random sequence too
(`bin/rust_conformance_fuzz qa/stress_domains/corrections native`, seed 1
of 10): Ruby's own `events` list contains real `EntryVoided` events Rust's
side has none of, and Rust's own `refusals` list answers `"unknown command
\"Corrections::Ledger.Void\""` (`TypeMismatch`) for the identical dispatch
Ruby accepted outright.

## 4. The `remove:`-then-`append:` identity-reuse question — asked, but the real answer is "the premise doesn't hold today"

The whole reason this domain exists to combine `remove:` and `append:` on
one entity list is `Hecks::Fuzzing::Properties::GUARANTEED_BY_CONSTRUCTION`'s
own `"Entity#identified_by"` entry (`properties.rb:159-165`): "Auto-minted
entities never reach the check (current.size + 1 can't repeat unless
something `remove:`s from the list between mints, which no real domain
does today)." Given finding 3 above, the honest answer is: **the premise
holds, but only vacuously** — no real domain does this today not because
nobody tried, but because `remove:` on an entity list does not work at all
yet, so the list can never actually shrink between mints, so the scenario
the comment worries about literally cannot arise on any domain that
exists. This domain is proof of exactly that: `Void` "succeeds" every
time and never once shrinks the list.

**A second, corroborating, currently-dormant bug this same investigation
surfaced, worth flagging alongside it:** the RUNTIME's own auto-mint rule
is `Value.for_attribute`'s sibling, `MutationApplier#next_identity`
(`command_interpreter/mutation_applier.rb:263-270`) — "ONE PAST THE
HIGHEST HELD (C4.5) — not `size + 1`, which repeats an identity the
moment the list has ever shrunk," i.e. `held.max.to_i + 1`, deliberately
NOT `size + 1`, because the runtime authors already fixed exactly this
class of bug once. But TWO comments describing the OLD, already-fixed
`size + 1` behavior are still live in the tree: `properties.rb:161-165`'s
own "current.size + 1" phrase (quoted above), and `lib/hecks/fuzzing/
sequence_generator/catalog.rb:102`'s "Entity#identified_by is filled by
`Array(current).size + 1`". Worse, the SECOND one is not just a stale
comment — `SequenceGenerator::OutcomeTracker#record_outcome`
(`lib/hecks/fuzzing/sequence_generator/outcome_tracker.rb:29`) genuinely
predicts the next auto-minted identity as
`(@entity_known_ids[key].size + 1).to_s` — the generator's OWN internal
tracking uses `size + 1`, not the runtime's real `max + 1` rule. This is
currently dormant and harmless ONLY because `remove:` is broken (finding
3): with nothing ever actually removed, `size` and `max`-derived-count
always agree. **The moment `remove:` is fixed to actually work, this
generator-side prediction goes out of sync with the real runtime's minted
identity** — a latent bug this domain's own investigation surfaced as a
byproduct, not something it set out to find. Not fixed here (`lib/hecks/
fuzzing/sequence_generator/**` is out of this PR's scope) — reported to
the orchestrator alongside findings 1-3.

## 5. `Ledger.ReplaceEntries` — the corpus's first `list_of(ENTITY)` command argument — no identity check at all

`sets :entries` (bare) on `ReplaceEntries` imports `Ledger`'s own declared
`list_of(Entry)` attribute onto the command verbatim
(`CommandBuilder#resolve_bare_set!`), the identical mechanism
`ConsoleSettings::Collection.ReplaceColumns` already uses for a
`list_of(VALUE OBJECT)` — untested for an ENTITY element type until this
domain (`Hecks::Fuzzing::SequenceGenerator::StepBuilder#args_for`'s own
comment, `step_builder.rb:79-96`, confirms: "a list-of-ENTITY command
attribute has no real example anywhere in this repo's domains" — this
domain gives that generator gap a concrete target; `list_value_for`
(`step_builder.rb:118-123`) still answers `nil` for it today, so
`ReplaceEntries` is never actually exercised by the RANDOM generator at
all — every occurrence in the seed scan above dispatched with `entries`
simply absent, refused `AbsentArgument`).

Confirmed by hand: `ReplaceEntries` with two elements sharing the SAME
`sequence` value (`{sequence: 99, ...}, {sequence: 99, ...}`) **succeeds
outright** — both land in the stored list. `#hydrate_entity_list`
(coercion.rb:416) rebuilds each element's own declared fields but never
runs `MutationApplier#check_entity_collision` — the guard every OTHER way
of adding an entity element goes through (`Record`'s own auto-mint path,
and any caller-supplied/composite append). A duplicate, or a missing,
identity both pass silently.

## 6. Two smaller, incidental findings from `bin/project_rust`/build

- **`FlaggedTrailCount` (rootless `count`, no `group_by`) is not generated
  for Rust at all** — `rust/project/read_models.rb#read_model_skip_reason`
  explicitly ports only ONE rootless shape, `group_by` alone
  (`AccountsByKind`, confirmed still generates fine for `examples/banking`
  separately). A rootless `count`/`median` hits the generic root-fetch
  check and refuses: `"declares reference_to , but includes no matching
  aggregate head."` Pre-existing, not introduced by this domain — logged
  here because this is, as far as could be checked, the first rootless
  `count` read model anywhere in the corpus to actually try it.
- The domain compiles clean (`cargo build --release --no-default-features
  --features corrections`, zero errors) and the CLI conformance binary
  runs correctly for every OTHER verb in the domain.

## What was NOT done here

No runtime code was fixed — findings 1, 2, 3, 4, and 5 are all reported to
the QA orchestrator, per this task's own scope. No Bug was logged against
the live QualityControl ledger (never booted by this work). `lib/hecks/
fuzzing/sequence_generator/**`, `step_builder.rb`, and `bin/qa_sweep` were
read for investigation only, never edited.
