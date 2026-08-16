# PRD 07 — Automated mutation testing of hecksagain's own Ruby source

**Status:** Not started. No harness exists — confirmed: no `mutant` gem, no
custom script, no CI step, nothing beyond a single comment describing a
one-off manual exercise.

## The problem

Two different things both go by "mutation" in this codebase, and it's worth
being precise about which one this PRD is:

- The **DSL's own** `append`/`remove`/`multiply`/`clamp` "mutations" — a
  declared, first-class language construct, extensively covered by this
  session's own `mutations_match_recompute` property. Not this PRD.
- **Mutation testing as a QA technique** — deliberately mutating
  hecksagain's own Ruby *source code* (flip a comparison operator, delete a
  guard clause, change a boundary) and checking whether the test suite
  actually catches it. This is what this PRD builds.

The only trace of this second sense anywhere in the repo is a comment in
`lib/hecksagain/runtime/command_interpreter.rb`:

> "Mutation testing found this the other way round: the only two
> declarations in banking whose removal changed observable dispatch
> behaviour were both `identified_by`."

That describes a real, one-off, **hand-done** exercise — removing bluebook
*declarations* one at a time and watching for behavior change, closer to
`Bluebook::MetaValidator`'s own domain than to a Ruby-source mutant run —
not a repeatable tool. No automated version of either sense exists.

## Why this is worth doing, and why it's sequenced late

Mutation testing is the classic technique for finding **weak assertions** —
tests that pass regardless of whether the code they claim to verify is
correct (an `expect(result).not_to be_nil` where the real bug would still
produce a non-nil, just wrong, result). Given how much of this session's own
work was property-based (recomputing an *independent* expectation rather
than asserting against production's own answer), there's a real chance this
codebase's assertion discipline is already unusually strong — but "probably
strong" isn't "measured," and this is the technique that measures it.

It's sequenced after the cheaper PRDs in this set on purpose: it's the
highest infrastructure cost here (tooling setup, and a mutation run is
inherently `O(mutants × suite runtime)` — slow even on a fast suite), and
the other PRDs are more likely to find something concrete faster. Do this
once there's already momentum from earlier wins, not as the opening move.

## Approach

1. Evaluate `mutant` (the standard Ruby mutation-testing gem) against this
   codebase's real constraints — it has known friction with metaprogrammed/
   DSL-heavy code, and this codebase's own `Bluebook`/`Builder` layer is
   exactly that. Confirm it's usable before committing to it; if `mutant`
   itself struggles to even generate sensible mutants against the DSL
   builder layer, that's a real finding worth reporting rather than forcing
   through.
2. **Scope narrowly first** — `lib/hecksagain/runtime/command_interpreter.rb`
   and its own `mutation_applier.rb`/`argument_gate.rb` siblings (the
   dispatch pipeline, already the most heavily property-tested code in the
   runtime, so a good place to find out whether "heavily tested" and
   "well-asserted" are actually the same thing here). Do not attempt the
   whole gem on the first pass.
3. Every surviving mutant (a mutation the suite didn't catch) is a real
   finding — either a genuinely untested branch, or a weak assertion.
   Triage each: fix the test, or confirm the mutant is behaviorally
   equivalent (some are — a mutation that produces provably identical
   behavior isn't a gap) and document why, the same "measured, not
   assumed" discipline this whole set of PRDs already holds to.

## Acceptance criteria

- [ ] A real mutation run completes against `command_interpreter.rb` +
      immediate siblings, with a concrete mutation-kill rate reported (not
      "seems fine" — an actual number).
- [ ] Every surviving mutant is triaged: fixed, or documented as
      behaviorally equivalent with a one-line reason.
- [ ] A decision recorded on whether to widen scope beyond this first pass
      (this PRD's own acceptance doesn't require widening — that's a
      follow-up call based on what the first pass actually finds).

## Non-goals

- Mutation-testing the entire gem in one pass — start narrow, expand only
  if the first pass proves the tooling works cleanly against this
  codebase's style.
- Automating the *other* sense of "mutation testing" (removing bluebook
  declarations one at a time) as a repeatable tool — that's a genuinely
  different, smaller idea (closer to `bin/model_check`'s own territory)
  worth its own, separate PRD if it turns out to matter; conflating the two
  here would blur what this PRD is actually measuring.
