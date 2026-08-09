# Guides

*Not doctested itself — an index. Every guide it points to is; see
[AUTHORING.md](AUTHORING.md) if you're about to write one.*

Each guide answers a decision you actually have to make — which field
wants a value object, how a rule refuses, what a query can and cannot
reach — with a real example the suite runs before you read it. If a
guide is wrong, it goes red.

Start at the top if you're new; jump straight to the one you need if
you're not.

1. **[Getting started](getting-started.md)** — a domain declared, wired,
   booted, and refused, in one sitting.
2. **[Aggregates and value objects](aggregates-and-value-objects.md)** —
   identity, shape, closed sets, and the trap in nesting them.
3. **[Commands](commands.md)** — everything a command may do, everything
   it may refuse, and the roster of refusal classes you'll actually hit.
4. **[Queries and read models](queries-and-read-models.md)** — what the
   build-time seal catches for you, and the one open question it doesn't.
5. **[Lifecycles](lifecycles.md)** — states, transitions, and what
   `bin/model_check` flags before you ship one wrong.
6. **[Entities](entities.md)** — identity and behavior that lives inside
   an aggregate, never addressed alone.
7. **[Policies and process managers](policies-and-process-managers.md)**
   — reactions, sagas, correlation, and the depth limit that keeps a
   feedback loop from becoming an incident.
8. **[Wiring](wiring.md)** — the hecksagon and the world: what's decided
   where, and why persistence is never the domain's problem.
9. **[Schema evolution](schema-evolution.md)** — a shape change, and
   proof that the data underneath it survives. Needs a real Postgres.
10. **[Verification](verification.md)** — model_check, fuzz, the corpus,
    and which one to reach for at which stage of actually shipping.
11. **[Writing an adapter](writing-an-adapter.md)** — the contract a new
    persistence or driving adapter has to keep, walked against the
    smallest real one.
12. **[Extending hecks](extending-hecks.md)** — adding a word to the
    language itself, and the conformance gates that stop it drifting
    from what it says.
13. **[Running a runtime](running-a-runtime.md)** — a second runtime
    exists (`rust/`); this is how it works and how to run or extend
    it: the canonical IR's exact shape, the dispatch order, and how
    the expression grammar `given`/`ensures`/`invariant` compile down
    to.
