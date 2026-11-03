# `corrects` — retroactive correction is an appended fact, never a rewrite

**Status:** Implemented.

## Context

The language's closed construct set was criticized on the grounds that a fixed vocabulary of deterministic, typed, boolean-gated state transitions cannot describe every real business process. Working through that criticism concretely turned up one gap adapters and hecksagon wiring cannot dissolve: **retroactive correction** — a fact this domain already recorded and already cascaded to other aggregates through `policy`, discovered later to have been wrong.

Three existing mechanisms look like they might cover this and none of them do:

- **Sagas' compensating legs** (`ProcessManager`) undo *anticipated* failures of *their own* process, triggered by *their own* refusal, in the *same run*. `CorrectFee` is not compensating a failed dispatch — `ApplyFee` succeeded correctly against the rules that held at the time; the fact underneath it turned out to be wrong days later.
- **Eras/translation** reinterpret stored *shape* under a schema-version boundary, applied at read time, to a whole cohort of records. They never rewrite what happened, and they don't target one specific record's business fact.
- **An ordinary command** (which is what `CorrectFee` was, before this change) can reverse a balance, but carries no formal, checkable link back to the fact it corrects. Nothing stopped `CorrectFee` from running against an account that was never charged a fee in the first place — the `given` that guards it (`fees_cents.cents >= amount.cents`) is a fact about the CURRENT balance, not a fact about whether this correction is even meaningful.

The event log stays append-only on purpose — that's what makes the rest of the language auditable. So the fix cannot be "let a command rewrite or delete a past event." It has to be a new fact, honestly declared as a correction of an old one.

## Decision

**`corrects` is a new `command`-level word:** `corrects event, as:, reason:, reverses:`.

- **Stored as a mutation, not a new `Command` field.** The self-hosted meta-domain's own contract (`Command#mutations`) is already fully round-tripped; a genuinely new top-level field is not, and would need the scale of change ADR 0025 already documents for real new concepts. `corrects` rides the exact multi-binding `fields:` wire shape `append`/`delegates_to` already established (`op: "corrects"`, target the corrected event's name), the same reasoning `delegates_to`'s own comment gives for reusing that shape rather than inventing a parallel one.
- **`reason:` is data, not documentation.** Unlike `goal`, a blank `reason:` is refused at declaration — an audit trail has to say why, not just that.
- **Two build-time refusals, before any dispatch runs:**
  - `corrects` naming an event nothing in the aggregate ever `emits` is refused the moment the aggregate finishes building (`AggregateBuilder#seal_correction_targets`) — a fact nothing in this domain ever announces is an authoring mistake, not a business rule to enforce at runtime.
  - `reverses: true` against an original command whose mutations include a non-invertible op (see below) is refused at the same point.
- **One dispatch-time refusal, a fact about the record in hand:** `NothingToCorrect` — this specific record must have actually emitted the named event before it can be corrected. Checked structurally (`CommandRules::Admissibility#enforce_correction_target`), the same way `NotFound`/`AlreadyExists` are, because it is not a predicate the expression evaluator can read off the record's own fields.
- **The cascade to whatever else already reacted is not a new mechanism.** A `corrects` command still `emits` an ordinary event; `policy` reacts to it exactly like any other event, with `with:` projecting whatever fields the reaction needs. Retroactive correction needed one new fact (*this amends that*), not a new dispatch path.

### `reverses: true` — structural auto-derivation, honestly scoped

`reverses: true` asks the runtime to derive the corrective `sets` from the original command's own mutations, rather than the author writing them. This is genuinely two different mechanisms, and only one is implemented:

- **Structural inversion (implemented): `increment` ↔ `decrement`.** The same argument, the opposite verb — `CommandRules::Arithmetic` applies `current + sign * amount`, so the same source with the opposite sign undoes it exactly, with no runtime data needed. `AggregateBuilder#seal_correction_targets` performs this derivation at build time.
- **`append` ↔ `remove` (explicitly NOT implemented).** These look symmetric and are not: `append`'s source is a per-field binding hash (`append: { name: :name, amount: :amount }`), `remove`'s is a single resolved value matched by equality (`MutationApplier#removed`). Collapsing one shape into the other correctly needs the target list's own value-object field names, not just the mutation's own recorded shape. Refused at build time rather than guessed at.
- **`set`/`multiply`/`clamp` (structurally impossible, not just unimplemented).** `set` needs the specific prior value at the moment the original fired — per-instance runtime data no build-time derivation can have (this is the "dynamic inversion" case: it would need the event log itself to carry pre-mutation state, which it does not today, and is real, separate future work, not attempted here). `multiply`/`clamp` are lossy by design — a clamped value's own pre-clamp magnitude is not recoverable from the mutation at all.

A command declaring `reverses: true` may not also declare its own `sets` — two ways of saying the same thing.

### `as:` — recorded, not yet wired

`as:` binds a name for the located instance being corrected, the same shape `ensures`'s own `old` binding already has. It is stored (always coerced to a plain string, never left a bare Symbol — a Symbol field elsewhere in this wire shape means "resolve against one of this command's own declared attributes," which `as:` does not mean) but **not yet exposed inside `given`/`ensures`** — no expression-evaluator wiring exists for it yet. Recorded now so the DSL surface doesn't need a second change later; the runtime consumer is a real, separate future round.

### Naming — a known, deliberate collision

`reverses` is separately earmarked (comment-only, unshipped) in `lib/hecks/bluebook/process_manager.rb` for a future saga-compensation feature (`reverses` on the step it reverses, replacing the current hand-written `on :refused` leg). This ADR's own author was shown that collision and chose to use `reverses:` for commands anyway. Whoever builds that saga feature should read this ADR first and make a deliberate choice — reuse this word's meaning, or pick another — rather than colliding by accident. A cross-reference comment is left at the `process_manager.rb` site pointing here.

## Consequences

- **Both runtimes move together.** The Ruby grammar (`command.bluebook`'s `KeywordSeed`/`ArgumentSeed` rows), the Rust parser mirror (`rust/parser/src/parse/command.rs`, `ir.rs`, `emit.rs`), and the generated `rust/parser/src/keywords.rs` table all carry `corrects`. `spec/parser_parity_spec.rb --tag io` confirms byte-identical IR for the real corpus, including banking's own `CorrectFee` use. Rust's `codegen` layer needs no change for the shipped scope — `reverses: true`'s structural derivation happens at Ruby build time, producing ordinary `increment`/`decrement` mutations Rust already codegens; nothing about `corrects` itself needs to execute inside generated Rust.
- **A real, latent bug in `lib/hecks/projections/diagrams.rb` surfaced and was fixed.** `mutation_label` special-cased `shape[:op] == :append` for the `fields:` wire shape instead of checking for the presence of `fields:` itself — meaning any real corpus use of `delegates_to` (structurally identical) would have hit the same crash. `corrects`'s own corpus use (`Account.CorrectFee`) is what exposed it; the fix generalizes to cover `delegate` as well, not just `corrects`.
- **A real corpus consumer, not a synthetic one.** `Account.CorrectFee` (`examples/banking/bluebook/deposit_accounts.bluebook`) now declares `corrects "FeeApplied", reason: "..."` — it already existed as a hand-rolled reversal; this makes its link back to the fact it corrects a checked one instead of an implicit one.
- **Golden fixtures regenerate deliberately, not silently.** `spec/golden/ir/{Banking,Bluebook}.json` and `docs/generated/diagrams/banking/Account_surface.mmd` were regenerated as part of this change and reviewed, not discovered as unexplained diffs later.
- **The generated reference page regenerates from the grammar; the prose is hand-written.** `docs/implemented/reference/command.md`'s `## corrects` section's table is 100% generated (`bin/reference`); its prose and runnable example (a full `ApplyFee`/`CorrectFee` cycle against the real banking domain, plus the `NothingToCorrect` refusal) were written by hand and pass `spec/reference_doctest_spec.rb`.

## Sequenced work plan (as executed)

| # | Change | Files |
|---|---|---|
| 1 | Grammar: `corrects` word + args, `NothingToCorrect` refusal, `corrects` MutationOp | `language/bluebook/command.bluebook`, `language/bluebook/vocabulary.bluebook` |
| 2 | Ruby builder + IR plumbing | `bluebook/dsl/command_builder.rb`, `bluebook/command.rb`, `bluebook/meta_validator/{readings,shapes}.rb`, `bluebook/assembly/marks.rb` |
| 3 | Build-time validation (event exists, `reverses:` derivation/refusal) | `bluebook/dsl/aggregate_builder.rb` |
| 4 | Runtime refusal (dispatch-time) | `runtime/errors.rb`, `runtime/command_rules/admissibility.rb`, `runtime/command_interpreter.rb` |
| 5 | Regenerate `lib/hecks/vocabulary.rb`, `rust/parser/src/keywords.rs` | `bin/project_vocabulary`, `bin/project_parser_table` |
| 6 | Rust parser mirror | `rust/parser/src/{ir,emit}.rs`, `rust/parser/src/parse/command.rs` |
| 7 | Real corpus use + fix the diagrams bug it surfaced | `examples/banking/bluebook/deposit_accounts.bluebook`, `lib/hecks/projections/diagrams.rb` |
| 8 | Docs, golden fixtures, conformance-spec registrations | `docs/implemented/reference/command.md`, `spec/golden/ir/*.json`, `docs/generated/diagrams/banking/*.mmd`, `spec/{syntax_conformance,dsl_coverage,vocabulary_conformance,dsl}_spec.rb` |
| 9 | Runtime + DSL specs | `spec/runtime/corrects_spec.rb`, `spec/dsl_spec.rb` |

## Rejected alternatives

- **A new top-level `Command` field.** Rejected for the reason `delegates_to` already established: it needs the self-hosted meta-domain's own grammar taught a new concept, the same scale of change as adding a wholly new construct — disproportionate to what `corrects` actually needs to carry.
- **Auto-deriving `append`/`remove` reversal too.** Looked plausible, turned out to need information (the target value-object's own field names) the mutation's recorded shape doesn't carry. Refusing it at build time was chosen over a plausible-looking but occasionally-wrong derivation.
- **Making `reverses: true` cover `set` by extending the event log to carry pre-mutation values now.** Real, and worth doing, but a materially bigger change (a wire-format change to every persisted event, both runtimes, every adapter) than this round's scope — left as explicitly future work rather than bundled in.
- **A generic "undo" or "rollback" construct spanning aggregates.** Considered and rejected outright — retroactive correction across aggregate boundaries requires each downstream aggregate to decide its own meaning of "corrected" (a policy reacting to the correction event), which is exactly what `policy` already does. A cross-aggregate auto-undo mechanism would need to know what every downstream consumer meant by "undo," which in general it cannot.
