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

## Plan questions

- What is the smallest slice that answers the need, and does the plan stop there?
- Which port does each new outside dependency use?
- What does the plan leave out on purpose, and does it say so?
