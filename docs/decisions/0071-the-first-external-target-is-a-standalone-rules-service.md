# The first external adoption target is a standalone rules service

**Status:** Accepted — partly implemented. Date: 2026-09-27. The two pieces the target needs (see "Consequences") now exist as `docs/running-a-rules-service.md`, with its known gaps listed. The exit test, an outside team following it with only the docs, has not been run.

## Context

The roadmap is wider than one team can serve at once: Rails integration, an OIDC provider, ISO traceability, an onboarding domain, UL projections, SQL stored-procedure compilation and more. The ticket that gathered the options is `docs/wayfinder/review-followup/tickets/10-adoption-wedge.md`. `docs/HECKS_IMPLEMENTATION_PLAN.md` is dated 2026-08-07 (its header, line 7) and part of it is stale, so this ADR quotes the plan's own status labels and does not restate sizes. Its sections 12 and 15 to 24 carry labels such as "New executable protocol projection" (line 1310), "New projection class" (line 1433), "New onboarding feature" (line 1614) and "New adjacent workflow" (line 1828). Sections 28 and 29 are "New product layer" (line 2038) and "Research/product tooling" (line 2083).

What is proven and what is not, from the same ticket and the code:

- **A rules-heavy backend spoken to over HTTP or JSON by a non-Ruby client is proven.** A production deployment runs on the Rust host (`rust/host/src/api.rs:1-8`), and the host has its own sign-in and session code (`rust/host/src/auth.rs:1-15`).
- **Hecks embedded in someone else's Rails app is not.** `docs/rails-integration.md` is marked "design only". What exists: the verb methods (`lib/hecks/facade/handle.rb:213-229`), a per-thread caller (`lib/hecks/runtime/caller.rb`, whose own comment calls the per-request caller "still-unbuilt") and a plain Rack app (`lib/hecks/forms/app.rb:23`). Missing, per the ticket: any `WebDoor`, generated routes, form helpers, a railtie or gem packaging, the read-side `index`, authorization, and any run inside a Rails app.
- **An agent-operated domain is not proven.** The README calls the MCP door "the least battle-tested item on this list" (`README.md:592-597`), and [ADR 0062](0062-mcp-servers-need-real-authentication-before-any-network-transport.md) is still a draft.

## Decision

1. **The first external adoption target is a standalone rules service.** A team outside the project runs the host behind an API, and its clients need not be Ruby.
2. **The exit test is:** an outside team defines a bluebook, deploys the host to their own account, and calls it from a non-Ruby client with only the docs.
3. **Rails integration is held as a fast-follow,** to start once one outsider has run a service. `docs/rails-integration.md` stays "design only" until then.
4. **The UL, onboarding, ISO traceability and OIDC-provider work is deferred until the exit test passes.** That is sections 12, 15 to 24 and 28 to 29 of `docs/HECKS_IMPLEMENTATION_PLAN.md`.
5. **The `group_by`, `sum` and dotted-`compute` correctness fixes are kept,** as [ADR 0065](0065-silent-wrong-constructs-are-refused-or-fixed.md) sequences them, because each costs a real user a correct answer.

## Consequences

- Two things the target requires do not exist. One is a documented path from `bin/project_deploy` to a running service that an outsider can follow. The other is an operator auth recipe for someone who is not the maintainer; `rust/host/src/auth.rs` exists, but no document walks another operator through using it.
- What an outsider can install interacts with [ADR 0066](0066-the-gem-ships-a-hecks-executable-and-dev-tooling-stays-in-the-repo.md), which decides what `gem install hecks` ships. An operator path that begins with `bin/project_deploy` starts from a clone until that ADR is built.
- The deferred sections stay in the plan, unstarted, and are not cancelled by this ADR.

## Alternatives considered

- **Rails integration inside a Rails app.** The largest build of the candidates: the missing list above, and an exit test that needs an outside Rails team to ship a bounded context in their own app. Held as the fast-follow (decision 3).
- **Agent-operable domains via MCP.** The least mature surface, its security ADR is a draft, and its user is an unsupervised agent. Not chosen as the first target.
- **Hold and pick nothing.** Cuts nothing, and leaves no exit test to say when the work has worked.

## Open items

- Is there a named outside person or team who would run this? The exit test needs an actual user.
- Does "outside" exclude the owner of the existing production deployment, and does it need someone beyond the maintainer's current collaborators?
- Does the outsider host the service themselves (the exit test as worded says "their own account"), or does the project host it for them? The two change the recipe and the support cost.
- Which is the audience to serve first, the AI-agent thesis or the Rails audience? Decision 1 picks a service, not an answer to that question.
- Should the UL, onboarding and ISO arc be cut outright rather than deferred?
- Should the exit test say how long the outsider's service must run, or what counts as having "run" one? The decision text does not say.
