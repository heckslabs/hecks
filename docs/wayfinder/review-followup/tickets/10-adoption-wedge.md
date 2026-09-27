---
type: grilling
status: open
blocked_by: []
claimed_by:
---

# Adoption wedge: one target and one external user first

## Question

The roadmap spans an OIDC provider, ISO traceability, an onboarding domain, UL projections,
SQL stored-proc compilation, and more. Rails integration is design-only. Decide the one wedge
(for example rules-heavy transactional backends inside Rails) or explicitly reject the premise,
what "one external user running it" means as the exit test, and which roadmap items are cut or
deferred until then.

## Prep (not a decision)

Gathered by a read-only agent for the grilling session; the options and recommendation are
input, not the decision. The roadmap docs are dated 2026-08-07 and 2026-08-18 and part stale,
so sizes are the docs' own labels.

**Facts**
- Unbuilt, from README "Project status": Rails integration (design only, large), Drivers
  (`interval|cron|clock`), the standalone outbox relay and adapter-host protocol, mutation
  testing and coverage-guided fuzzing. From "Experimental or partial": query aggregation
  without `sum/avg/min/max`, the `group_by` row drop, the PostgresEra dotted-`compute` gap, a
  partial Rust `read_model` codegen, and no outbox on Heki, LocalStorage or D1.
- From `docs/HECKS_IMPLEMENTATION_PLAN.md` (34 sections, many marked Done, so stale): a SQL DDL
  projection with stored procedures ("research-grade, gates nothing"), a real OIDC client flow
  and an OIDC provider, email OTP, a UL projection and adoption recipe, an onboarding domain,
  role mapping and discovery, AI mapping suggestions, drift detection, ontology upgrades, ISO
  traceability, conformance drift, era-addressable queries and historical reports. Most of
  sections 15 to 24 and 28 to 29 rest on canonical bluebooks and onboarding, which nothing in
  the repo shows a user needing.
- Rails (`docs/rails-integration.md`, "design only"): the verb methods it says must land first
  exist (`lib/hecks/facade/handle.rb:213-229`), the per-thread `Runtime::Caller` exists, and a
  plain Rack app serves HTML and JSON (`lib/hecks/forms/app.rb:23`). Missing: any `WebHandle`
  or `WebDoor`, generated routes, controller or form helpers, a railtie or gem packaging, the
  read-side `index`, authorization, and any run inside a Rails app. The README has no Rails
  quickstart.
- What is proven: a rules-heavy transactional backend spoken to over HTTP or JSON by a non-Ruby
  client, with Ruby and Rust enforcing the same rules. The repo shows a production deployment
  on a Rust host with Postgres eras (`rust/host/src/api.rs:1-8`), and all four example domains
  are checked for Ruby-versus-Rust byte parity. Not proven: hecks embedded in someone else's
  Ruby or Rails app, and an agent-operated domain in the field (the MCP door is the least
  battle-tested surface, `README.md:596`).
- Dependencies: the network-facing door needs ADR 0062 and *MCP door auth*; Drivers and the
  outbox relay are independent; the Rails wedge needs its whole open list plus Governance for
  authorization.

**Candidate wedges**
1. Rules-heavy transactional backend inside Rails. Largest build (`WebDoor`, routes, form
   helper, per-request caller, authorization, `index`, packaging). Exit test: an outside Rails
   team ships one bounded context in their own app for 30 days.
2. Standalone rules service behind an API. Needs a documented path from `bin/project_deploy` to
   a running service and an operator auth recipe for an outsider. Exit test: an external team
   defines a bluebook, deploys the host to their own account and calls it from a non-Ruby client
   with only the docs. Makes cuttable: the Rails design, the OIDC and OTP work, and the UL,
   onboarding, ISO and drift arc.
3. Agent-operable domains via MCP. Least mature surface, security ADR still Proposed, and the
   user is an unsupervised agent.
4. Hold and pick nothing. Cuts nothing and leaves no exit test.

**Recommendation from prep.** Wedge 2, with Rails held as a fast-follow once one outsider has
run a service. Cut or defer the authority and ontology arc until then, and keep the
`group_by`, `sum` and dotted-`compute` fixes because they cost a real user correctness.

**For the maintainer**
1. Is there a named outside person or team who would run this? The exit test needs an actual
   user.
2. Does "one external user" exclude the existing production deployment's owner?
3. Their own hosting, or hosted by you? Both change the recipe and the support cost.
4. Which do you value more, the AI-agent thesis or the Rails audience? That decides wedge 2
   versus 3.
5. Willing to cut the UL, onboarding and ISO arc outright rather than defer it?

## Answer
