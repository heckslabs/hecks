# Restart prompt — hecksagain

Paste this into a fresh session.

---

We are building **hecksagain** at `~/Projects/hecksagain` — Hecks rewritten with
Ruby as the source of truth. Read `README.md` first, then this.

## The thesis

Both runtimes are hand-written. Ruby holds the semantics; Rust is a second
implementation held to Ruby's answers. Parity is a claim about OUTPUT, not
origin: the same source file in, the same answers out, **as far as the corpus
reaches**. `bin/parity` is what makes the claim real.

Do not call Rust a projection. Nothing generates it.

## Standing rules

1. **Never modify `~/Projects/hecks`** unless asked.
2. **Don't hand-write what Hecks already has** — cherry-pick whole. But
   simplifying is not copying; that is how `creates?` regressed.
3. **The DSL constructs the Ruby classes.** `Pizza.create_pizza(...)` is the
   public surface; `dispatch` is private plumbing.
4. **Zero warnings, zero failing tests.**
5. **Tests do no IO** except `spec/adapters/`.
6. **Ruby wins when the shapes differ.** The exporter converts. Never bend a
   bluebook to suit an interpreter.

## Current state

    main                     PR #1 and #2 merged
    experiment/self-hosting  e4fb90e — 9 commits ahead, pushed

    bundle exec rspec                             396 examples, 0 failures (4.6s)
    cd rust && cargo test --release --workspace   177 passed, 0 warnings
    bin/parity     AGREED — banking 103/193 · pizzas 5/18 · grammar 27/37

Repo is on GitHub, private: `chrisyoung/hecksagain`.
`core.hooksPath` is LOCAL config — a fresh clone needs
`git config core.hooksPath .githooks` or the pre-push parity gate is silent.

## What the language now is

`lib/hecksagain/language/bluebook.bluebook` declares what a bluebook IS.
`lib/hecksagain/language/world.bluebook` declares what a world is.
`lib/hecksagain/bluebook/meta_validator*` dispatches every built IR into them at
load; any refusal becomes `Malformed`.

**Eleven rules live in the language and nowhere else** — their `raise Malformed`
is deleted:

    an event is named · an attribute is named · a vision says something
    a description says something (aggregate and read model)
    a rule says what it means (givens and invariants)
    a mutation names a target · a command names what it acts on
    a closed set admits a member · a realm says something
    a latest version says something

Plus two that became STRUCTURE rather than predicates: an attribute's type is a
`reference_to ValueObject`, so a primitive fails reference resolution.

`spec/fixpoint_spec` judges the language by its own rules. It passes.

`HECKSAGAIN_META_VALIDATION=off` shows what it is holding.

## THE OPEN THREAD — a generic judge

`meta_validator/judge.rb` is ~140 lines of per-category dispatch. The aggregates
were renamed to the words they describe (Bluebook, Aggregate, Command,
ValueObject, Query, Entity, Policy, ProcessManager, ReadModel, Handler,
Dispatch) precisely so the judge could become a WALK: find the aggregate of the
same name, offer each field by name.

**It does not work yet, and I backed it out.** Top-level fields walk fine.
Nested collections do not: a command's attributes / givens / mutations are
value-object LISTS appended by separate commands (`Command.Argument`,
`Command.Rule`, `Command.Change`), and which append command belongs to which
list is not derivable from a name. Making it derivable means modelling every
nested collection as its own root — a real remodelling, not an afternoon.

If attempted: **parity is the gate.** Change Ruby's side only, keep Rust as the
control, and `AGREED` means the walk is faithful.

## Findings recorded, NOT fixed

- **Read-model uniqueness** (`already projects X`) is the last rule that cannot
  port. It needs to see inside a list, and the sublanguage has no quantifier and
  cannot reach an element's fields. Costed three ways: a quantifier (~100 lines
  both runtimes, but it introduces LEXICAL SCOPE and permanently raises the
  floor every future runtime pays), a pluck primitive (~60 lines, first-order,
  uglier), or leave it.
- **`role` and `goal` were never required** by the builders. Banking declares
  neither on 19 of 40 commands; pizzas 3/3 and grammar 16/16 declare both. The
  language has no opinion. Whether it should is a design decision, not a defect.
- **21 of 62 value objects in the language are `{ value: String }` with no rule**
  — ceremony forced by "attributes must be value objects" plus per-aggregate VO
  scoping. ~80 lines of nothing. Worth asking whether the rule should apply to
  every field or only to fields that carry meaning.
- **Self-hosting does not delete code.** Measured three times: ~+200 lines net.
  862 (dsl) + 479 (ir) + 1002 (runtime), and nearly all of it is irreducible — a
  keyword surface, data classes the interpreter reads, and an interpreter. If a
  smaller codebase is the goal, this is not the route.
- **The floor is IO PLUS the interpreter**, not IO alone. A `given` is a closed
  predicate over its own attributes, so a predicate held as DATA cannot be
  evaluated, a dynamic mutation target cannot be set, and a data-named verb
  cannot be dispatched. ~390 lines of expression evaluator stay hand-written in
  every target language.

## Findings worth not rediscovering

- **Agreement is not correctness.** Both runtimes can be equally wrong and
  parity stays green. `bin/parity` now prints an execution census and FAILS on a
  silent corpus — pizzas once reported AGREED while executing NOTHING.
- **A rule the judge never offers input to cannot fire.** Twice in the validator
  alone: five rules declared and unreachable, then policies, process managers
  and entities unjudged. `spec/judge_coverage_spec` guards it.
- **Moving a rule is the easiest moment to lose one.** Two were lost while
  porting — one had no counterpart declared; one was reported as a runtime bug
  when it was a malformed bluebook I had written. Only the specs pinning the old
  rules caught them. A spec per ported rule is not optional.
- **ABSENT is not EMPTY.** Passing `""` for a nil turned every "if you declare
  it, declare something" rule into "you must declare it" — 73 examples refused.
- **A command argument SHADOWS the aggregate field of the same name** inside a
  given. Three sightings. A once-only rule cannot read the state it guards
  unless the two differ.
- **`identified_by :name` forbids an argument named `name`** — the runtime reads
  it as the reference lookup.
- **Raw Ruby errors leak as refusals.** `no implicit conversion of Symbol into
  Integer` appeared four times. `Runtime::DOMAIN_REFUSALS` declares the boundary
  and `spec/domain_refusal_spec` enforces it.
- **The IR is a shared contract.** Adding a field on one side splits parity
  immediately — twice (`closed_set`, and the ORDER of a synthesised value
  object). Field for field AND index for index.
- **`bin/parity` takes the first `.bluebook` in a folder.** Two files in one
  directory silently displaced a corpus member. The meta-domain lives in
  `lib/hecksagain/language/` so joining the corpus is deliberate.
- **`cd ~/Projects/hecksagain && …` on every command** — the session cwd is not
  this repo.

## Things a fresh session should NOT redo

- **Do not rebuild a round-trip harness.** `experiment/replay.rb` proved every
  corpus IR round-trips byte-identically, then was retired: reconstruction is
  not needed for validation, and parity answers the question better. It IS
  needed if the meta-domain ever becomes the IR rather than its judge.
- **Do not call a rule unportable without checking.** Both rules called
  unportable turned out fixable — one by removing it (a data dependency, not an
  ordering rule), one by recording in the IR what the author had declared.
- **Do not trust green.** Every real defect this session was found by probing by
  hand, not by the suite going red.
