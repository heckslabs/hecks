# Architecture review rubric

The `architect` agent reviews plans against these rules. Each has a number so a finding can cite it.
Change a rule here and the reviewer follows; the agent file holds no rules.

## D. Domain-driven design

- **D1.** One command changes one aggregate. A plan that changes two in one step needs a policy and
  an event between them.
- **D2.** Aggregates refer to each other by id, never by holding the other aggregate.
- **D3.** An invariant lives inside the aggregate it protects, not in a caller or an adapter.
- **D4.** Names are the domain's own words. A new name that the bluebook does not use, or a second
  name for something it already names, is a finding.
- **D5.** Commands are intents in the imperative; events are facts in the past tense. A command
  does not describe a fact, and an event does not ask for anything.
- **D6.** Contexts do not share aggregates. What crosses a boundary is an event or an id, read through
  the context map.
- **D7.** Every new fact has one owner. If the plan does not say which aggregate owns it, ask.

## H. Hecks

- **H1.** Rules live in the bluebook. An adapter measures and fetches; it decides nothing.
- **H2.** One adapter per port. Two adapters on one port fail at boot (`WiringError`); a plan that
  adds an adapter to an existing port must say which one it replaces.
- **H3.** Commands return ids for later calls. Context is read-only, never used for a write.
- **H4.** Records are append-only. A change is a new record that supersedes, not an edit.
- **H5.** Repository work goes through Hecks commands (`LinkedTree`, `Landing`, `SendTrain`, `ReviewRequest`), not raw
  `git` or `gh`. A step no command covers is said so in the plan.
- **H6.** Generated files (a `Generated ... do not edit` banner) are never edited; the plan names the
  generator or its source.
- **H7.** The changed domain passes `model_check`. A plan that adds to a domain says how it will be
  checked.

## X. Hexagonal

- **X1.** Dependencies point inward. The domain does not know an adapter exists.
- **X2.** The domain owns the port: its shape is what the domain needs, not what the outside offers.
- **X3.** An adapter is thin: facts in, facts out. A conditional on domain meaning in an adapter is a
  rule in the wrong place (H1).
- **X4.** The plan can be exercised without the outside world, through behaviors. Stand-ins stay out
  of the real wiring.
- **X5.** Few ports. A port per source or per purpose is too granular; purposes and sources are data.

## S. Size of the answer

- **S1.** A finding prefers removal to addition. When a gap can be closed by leaving the feature out,
  the finding says so first, and only then proposes a mechanism.
- **S2.** The verdict names the smallest version of the proposal that still meets its goal.

## V. Verdict

A review exists so a coder can build, not so a plan is perfected. Of 364 verdicts to 2026-11-15, 313 were
`changes`, 41 `rethink` and 10 `sound`, so nearly every item took a second round. A finding is one of two kinds.

- **Blocking.** Building the plan as written would break a rule below with evidence from the repo or a tool
  result, or would fail: a source that does not exist (D7, H1), two adapters on one port (H2), an invariant
  outside its aggregate (D3), a generated file edited (H6), a domain that will not pass `model_check` (H7),
  a dependency that points outward (X1).
- **Note.** Everything else: a name that could be the domain's own (D4), a smaller slice (S1, S2), a check
  the plan could add, a missing line of detail the coder can settle from the code (D5, D7 when one owner is
  obvious), wording. A note carries no evidence of failure. A missing owner or source with no obvious
  answer is the D7 case that blocks.

The verdict follows from the blocking findings alone.

- `sound`: no blocking finding. Notes ride along under a `Notes` heading, and the coder applies them while
  building. They are not sent back for another review.
- `changes` (written `sound with changes`): at least one blocking finding. Each says what to change.
- `rethink`: the goal is better met another way, so the plan as a whole is dropped. It is not a stronger
  `changes`.

**Measuring it.** `VerdictMix` counts the verdicts; the `Reviews` rows carry `requested_at`, so a day's mix is
those rows bucketed by `requested_at / 86400`, read from the main checkout (a worktree's store is empty). Baseline on 2026-11-15: 313 `changes` of 364. To sample, read the `Reviews` rows whose
verdict is `changes` and ask of each: did the coder's build differ from the plan as first written, because of a
blocking finding? A blocking finding the build ignored was a note, and the lines above are tuned to it. The goal
is `sound` as the common verdict on items the coder then lands unchanged.

A plan that names which aggregate owns each new fact and how it is checked is not sent back for detail.
When unsure whether a finding blocks, it is a note.

## Plan questions

- What is the smallest slice that answers the need, and does the plan stop there?
- Which port does each new outside dependency use?
- What does the plan leave out on purpose, and does it say so?
