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
2. **[Your own domain](your-own-domain.md)** — write a bluebook of your
   own, run it, and deploy it to AWS Lambda.
3. **[Aggregates and value objects](aggregates-and-value-objects.md)** —
   identity, shape, closed sets, and the trap in nesting them.
4. **[Commands](commands.md)** — everything a command may do, everything
   it may refuse, and the roster of refusal classes you'll actually hit.
5. **[Queries and read models](queries-and-read-models.md)** — what the
   build-time seal catches for you, and the one open question it doesn't.
6. **[Lifecycles](lifecycles.md)** — states, transitions, and what
   `hecks model_check` flags before you ship one wrong.
7. **[Entities](entities.md)** — identity and behavior that lives inside
   an aggregate, never addressed alone.
8. **[Policies and process managers](policies-and-process-managers.md)**
   — reactions, sagas, correlation, and the depth limit that keeps a
   feedback loop from becoming an incident.
9. **[Wiring](wiring.md)** — the hecksagon and the world: what's decided
   where, and why persistence is never the domain's problem.
10. **[Schema evolution](schema-evolution.md)** — a shape change, and
   proof that the data underneath it survives. Needs a real Postgres.
11. **[Verification](verification.md)** — model_check, fuzz, the corpus,
    and which one to reach for at which stage of actually shipping.
12. **[Writing an adapter](writing-an-adapter.md)** — the contract a new
    persistence or driving adapter has to keep, walked against the
    smallest real one.
13. **[Extending hecks](extending-hecks.md)** — adding a word to the
    language itself, and the conformance gates that stop it drifting
    from what it says.
14. **[Running a runtime](running-a-runtime.md)** — a second runtime
    exists (`rust/`); this is how it works and how to run or extend
    it: the canonical IR's exact shape, the dispatch order, and how
    the expression grammar `given`/`ensures`/`invariant` compile down
    to.
15. **[Behaviors](behaviors.md)** — hand-curated examples of how a domain
    is used, in its own vocabulary, run as tests: `hecks operation.run_behaviors`, the
    rspec shim, and what `emits:` sees through a real policy cascade.
16. **[Language versioning](language-versioning.md)** — how the bluebook
    surface itself carries `proposed`/`admitted`/`deprecated`/`retired`,
    and what `hecks language_run.rename` does with a rename.
17. **[Projections: Rust and WebAssembly](projections.md)** — the
    bluebook as the one definition, projected to generated Rust and WASM,
    and how that output is held equal to Ruby's.
18. **[AI-native development](ai-native-development.md)** — the
    storehouse bus and its MCP door: one checked surface an agent works
    through, and what its identity check does not do.
19. **[Project status](project-status.md)** — what works today, what is
    experimental or partial, and where the gaps are written down.

## Beyond the guides

- **[The DSL reference](../reference/index.md)** — one page per context,
  one runnable example per word.
- **[Architecture map](../../architecture-map.md)** — the `lib/hecks/`
  and `rust/` directory layout, and the dependency direction the split
  follows.
- **[The commands](../../tools.md)** — every `hecks <verb>`, with the `bin/` script it replaces.
- **[Running a rules service](../../running-a-rules-service.md)** — from a
  bluebook to a deployed API, with the auth caveats.
- **Resolution rules** — the exact algorithm behind every piece of DSL
  sugar that lets a bluebook omit something the runtime can derive:
  [overview](../../resolution-rules/README.md),
  [cross-entity given](../resolution-rules/cross-entity-given.md).
- **[Decision log](../../decisions/)** and
  **[implemented decisions](../decisions/)** — one
  document per architectural decision, kept even after superseded.
- **[Changelog](../../../CHANGELOG.md)** and
  **[1.0 readiness](../../1.0-readiness.md)**.
- **[The query DSL](../../query-dsl.md)**,
  **[command/query form](../../command-form-and-query-form-bluebook.md)**,
  **[Rails integration](../../rails-integration.md)** (design only).
- **[`docs/HECKS_IMPLEMENTATION_PLAN.md`](../../HECKS_IMPLEMENTATION_PLAN.md)**
  — the full aspirational architecture in one document. Treat this as a
  roadmap, not a status report; [Project status](project-status.md) is
  the status report.
