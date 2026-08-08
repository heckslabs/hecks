# HECKSAGAIN Architecture & Implementation Guide

> This document is the canonical engineering specification for HecksAgain.
> It combines architectural invariants, execution model, implementation guidance,
> and the feature roadmap into a single reference intended for humans and coding agents.

> **Restored 2026-08-07, corrected same day.** This document was drafted,
> committed (`ddb1ce2`), and then reset away — all within the same session
> — before any of §8's work actually started; a differently-architected
> Rust effort began fresh afterward on `feat/rust-projection` and is now
> substantially complete. §8/§9 below are rewritten to describe what was
> actually built, which diverges from this document's own original plan
> in ways worth reading (it does the opposite of one of §8's stated
> non-goals). Everything else in this document — Phases 1, 3–10 — was
> never started in the interim and is restored as originally written;
> spot-checked against the current codebase, not exhaustively re-audited
> section by section. `docs/decisions/000{1,2,7,8,9,10}` and
> `bin/rust_conformance`, both named throughout, are restored alongside
> this file and confirmed still running against the current codebase.

## How to use this document

Read the sections in order:

1. Architectural Philosophy
2. Architectural Invariants
3. Execution Model
4. Intermediate Representations
5. Semantic & Capability Graphs
6. Verification & Explainability
7. Core Language
8. Runtime
9. Supporting Bluebooks
10. Projections
11. Canonical Corpus
12. Feature Roadmap

---
# Part I — Architectural Foundation

# HECKSAGAIN_IMPLEMENTATION_PLAN

# Addendum: Foundational Architecture

## Intent as the Primary Artifact

HecksAgain models organizational intent rather than software
implementation. Bluebooks are the canonical description of *why* an
organization behaves the way it does. Runtimes, APIs, databases, user
interfaces, documentation, reports, AI assistants, and language
projections are all derived artifacts. Every new feature should first
ask whether it belongs in the intent layer before introducing
implementation-specific concepts.

## Execution Pipeline

Every command should move through an explicit deterministic pipeline:

1.  Intent resolution
2.  Runtime enrichment (UUIDs, clock, caller, external facts)
3.  Authorization
4.  Validation / invariants
5.  Policy evaluation
6.  Lifecycle evaluation
7.  Mutation planning
8.  Event planning
9.  Adapter execution
10. Persistence
11. Projection refresh
12. Evidence generation

Each stage should document: - Inputs - Outputs - Replay behavior -
Determinism guarantees - Failure semantics

## Three Intermediate Representations

### Authoring IR

Represents the canonical Bluebook independent of Ruby syntax. This is
the durable semantic representation consumed by projectors.

### Execution IR

Represents a fully bound command ready for execution after enrichment.
It contains resolved identities, caller context, generated identifiers,
timestamps, resolved references, and effective role information.

### Evidence IR

Represents the outcome of execution. It records accepted/refused
decisions, evaluated grounds, authority chain, mutations, emitted
events, adapter interactions, evidence hashes, and provenance.

These three IRs should remain independent.

## Capability Graph

The runtime should expose a graph of required capabilities and their
fulfillments.

Examples:

-   Governance
-   Identity
-   UUID
-   Clock
-   Persistence
-   Email
-   Payments

Fulfillments may come from Bluebooks or adapters. The graph should power
deployment analysis, onboarding, dependency visualization, and AI
reasoning.

## Semantic Graph

Canonical IR should expose a navigable semantic graph.

Examples:

Command -\> Role Command -\> Event Event -\> Policy Policy -\> Command
Command -\> Aggregate Aggregate -\> Record Record -\> Value Object

AI, projectors, verification, documentation, and visualization should
operate on this graph instead of parsing Ruby.

## Constraint Engine

Rules are constraints rather than simple validations.

The runtime should eventually explain blocked work by traversing
dependency chains and identifying the next satisfiable organizational
action.

## Explainability

Every runtime decision should produce an explanation tree.

Examples:

Accepted because... Refused because... Blocked because...

Different projections should render explanations for developers,
auditors, regulators, and business users without changing evidence.

## Verification

Add a verification subsystem capable of identifying:

-   Dead commands
-   Dead events
-   Dead policies
-   Cycles
-   Impossible transitions
-   Conflicting invariants
-   Duplicate rules
-   Unreachable states
-   Unused roles
-   Unused value objects

Target command:

    hecks verify

**Status note (2026-08-07 restore):** substantially real already, under a
different name — `bin/model_check` (built before this document was
first drafted, survived the reset that took the rest of this plan)
covers unreachable lifecycle states, transitions nothing can ever
fire, saga states no handler chain reaches, unreachable compensation
`from_state`s, dispatches to nonexistent commands, and handlers
listening for events nothing emits — all as static analysis over the
same canonical IR the runtime dispatches against, the lightweight
formal-methods leg this section describes. `given`/`ensures` (Design
by Contract pre/postconditions) also exist and are load-bearing
throughout the corpus and the Rust projection (`§8`) both. Not yet
covered here specifically: dead commands/events/policies, duplicate
rules, unused roles/value objects — the dead-code-shaped half of this
list, distinct from `model_check`'s reachability/consistency half.

## Visualization

Generate diagrams directly from canonical IR:

-   Aggregate graph
-   Role graph
-   Event graph
-   Policy graph
-   Lifecycle graph
-   Capability graph
-   Ontology graph
-   Projection graph
-   Upgrade graph

No hand-maintained diagrams should be required.

## AI Layer

AI should operate as an assistant rather than an execution engine.

Responsibilities include:

-   Ontology discovery
-   Canonical corpus evolution
-   Role mapping
-   Upgrade suggestions
-   Documentation generation
-   Drift explanation
-   Verification assistance
-   Pattern discovery
-   Standards discovery

Runtime behavior always remains deterministic.

## Architecture Decision Records

Every architectural invariant should be captured as an ADR. The
implementation plan and ADRs together become the durable engineering
memory of HecksAgain.

------------------------------------------------------------------------

These sections should be merged into the existing
HECKS_IMPLEMENTATION_PLAN.md. They elevate the execution model, semantic
graph, verification, and explainability to first-class architectural
concepts while preserving the small core language.


---
# Part II — Implementation Roadmap

# Hecks Implementation Plan

> Agent-ready engineering briefs for the next phase of Hecks.
>
> This document is intentionally implementation-oriented. Each feature states the current Hecks correlation, the target behavior, likely code seams, Ruby DSL examples, acceptance criteria, dependencies, and explicit non-goals. The goal is that an engineering agent can pick up one section and implement it without re-deriving the architecture from the original design conversation.

> **Scope note (2026-08-07):** this roadmap is pruned to unimplemented work only — `supporting` Bluebooks (formerly a separate item) is removed as already implemented. The Rust/WASM/host-language projection sections were briefly removed as obsolete after the Rust runtime retirement (`docs/rust-experiment.md`), then restored, then narrowed by decision: there is **one** Rust runtime target in this roadmap (`§8`, plus its WASM compile output in `§9`), not a family of separate host-language projections — the Ruby-hosts-Rust, Python, Go, and Java sections that used to describe a second, generic, IR-interpreting Rust core were removed rather than kept as speculative alternatives. `§8` itself is a code generator, not an interpreter: it consumes canonical IR at build time and emits native Rust source, one module per held era as an initial implementation (a scaling concern, not a permanent architecture — see `§8`). The governing invariant is that no canonical IR is parsed or interpreted at runtime; generated static metadata for introspection/diagnostics is fine as long as it's read, never interpreted as instructions. `§8` starts early (Phase 2, right after core hardening) rather than waiting for later IR-shaping work to finish — per `docs/decisions/0010-ruby-is-the-reference-implementation.md`, Ruby serves as both the implementer's guide and, through a continuously-run differential harness, the correctness oracle, so IR/behavior changes from later phases become fast-following, harness-verified extensions rather than a reason to have waited. This is explicitly framed as a *second attempt* that must not repeat the retired architecture (a hand-written second interpreter maintained through differential parity). Sections are renumbered sequentially; numbers no longer match any prior draft or external references to this document.

## Working rules for agents

1. Preserve the existing Bluebook grammar unless a feature explicitly requires syntax.
2. Prefer changes to IR, runtime, projections, adapters, or supporting Bluebooks over new keywords.
3. Preserve replay and era behavior.
4. Preserve existing Bluebooks unless a feature explicitly calls for a migration.
5. Every new semantic feature must round-trip through `to_h` / `Bluebook::Assembly`.
6. Every new projection should consume canonical IR rather than Ruby implementation objects where practical.
7. Every new imperative capability must enter through a port/adapter.
8. Do not introduce a second hand-written interpretation of Bluebook semantics unless explicitly approved.
9. Add focused specs next to the subsystem being changed, then add corpus/golden coverage where the wire representation changes.
10. Treat `lib/hecksagain/language/` and the self-hosted language declarations as load-bearing specifications, not documentation.

---

# 1. One command → one role

**Status:** Partially present  
**Priority:** P0  
**Complexity:** S

### Current correlation

Commands already carry a single `role` field through `Bluebook::DSL::CommandBuilder` and `Bluebook::IR::Command`. Runtime authorization already compares the current caller role against that field in `Runtime::CommandRules::Authorization`. The current language still allows commands with no role, and comments in the authorization code note that a meaningful portion of Banking currently declares none.

Likely files:

- `lib/hecksagain/bluebook/dsl/command_builder.rb`
- `lib/hecksagain/bluebook/ir/command.rb`
- `lib/hecksagain/runtime/command_rules/authorization.rb`
- `lib/hecksagain/language/bluebook/behavior.bluebook`
- `spec/runtime/authorization_spec.rb`
- `spec/corpus/*.json`

### Target behavior

A command may never declare *multiple* roles. The DSL already structurally satisfies this because `role` is a scalar assignment, but the invariant should become explicit in the language model and documentation. Whether every externally invokable command must eventually have a role should be a separate migration, because current role-less commands may represent system reactions or intentionally unguarded operations.

The immediate feature is therefore: **role cardinality is zero-or-one, with a roadmap toward exactly one for externally proposed commands.**

### Ruby DSL

```ruby
command "Withdraw" do
  role "Teller"
  goal "Give cash to an account holder"

  reference_to Account
  attribute :amount, Money

  given("the account has enough available funds") {
    balance.cents >= amount.cents
  }

  then_set :balance, decrement: :amount
  emits "CashWithdrawn"
end
```

Do not add this:

```ruby
command "Withdraw" do
  role "Teller"
  role "Branch manager" # invalid modeling; second assignment must not mean OR
end
```

### Implementation hint

Add a language-level statement to the self-hosted behavior grammar expressing that a command has at most one role. If the builder currently silently overwrites a second `role` call, make duplicate calls raise `Malformed` so authoring mistakes cannot disappear.

A simple builder guard is sufficient:

```ruby
def role(value)
  raise Malformed, "#{@name} declares role twice" if defined?(@role) && @role
  @role = value
end
```

Keep IR shape scalar:

```ruby
role: "Teller"
```

Do **not** change it to an array.

### Acceptance criteria

- A command with one role builds and authorizes exactly as today.
- A command with two `role` declarations is refused at declaration time.
- Existing role-less commands continue to boot in this feature.
- `to_h` still emits a scalar `role`.
- `Bluebook::Assembly` reconstructs the scalar exactly.
- Existing authorization specs remain green.

### Non-goals

- No role hierarchy in business domains.
- No multiple-role OR semantics.
- No position model here.
- Do not yet require a role on every command.

---

# 2. `act_as` authority transition

**Status:** Done (2026-08-07) — on a smaller shape than this section
originally sketched, and deliberately so. Re-reading the "Runtime execution"
sketch below closely showed `Governance.authorize_transition!` called by
APPLICATION code, before `Runtime::Caller.as(role:)` wraps a nested
dispatch — not woven into `CommandInterpreter`/`Dispatcher`/
`CommandRules::Authorization` at all. So none of those three changed.
`lib/hecksagain/framework/bluebook/governance.bluebook` gained a second aggregate,
`RoleTransition` (`from_role`/`to_role`, `Grant`/`Revoke`, an `Allowed`
query) — the fact "role X may act as role Y" that `RoleAssignment` alone
could not answer. `spec/act_as_spec.rb` demonstrates the full pattern
against two separate registries (Governance's own, and a real Pizzas
boot): an application checks `Allowed`, then wraps the downstream dispatch
in `Hecksagain.as_caller(role: ...)` ; the unauthorized-refusal path (no
`Allowed` row → the app-level check itself refuses, before any dispatch)
and the role-restoration proof (a THIRD dispatch, right after the nested
one, still authorized under the ORIGINAL role) are both covered. Also
confirmed and left alone on purpose: "replay does not invoke live
Governance decisions" was already true before this section existed —
`Fuzzing::Replay` never binds a `Caller`, and `refuse_role_mismatch`'s
first line is `return unless caller`. A facade-level `calls "...", as:
"..."` sugar (this section's own DSL sketch below) is real, later work —
see "Non-goals".  
**Priority:** P0  
**Complexity:** M

### Current correlation

`Runtime::Caller` already provides:

```ruby
Hecksagain::Runtime::Caller.as(role: "Teller") { ... }
```

and authorization reads that ambient role. Dispatcher reactions explicitly clear caller context because system reactions should not inherit the initiating human's authority.

That is very close to the execution primitive required for `act_as`, but today it is merely a runtime caller binding rather than a governed, declared cross-command transition.

Likely files:

- `lib/hecksagain/runtime/caller.rb`
- `lib/hecksagain/runtime/dispatcher.rb`
- `lib/hecksagain/runtime/command_interpreter.rb`
- `lib/hecksagain/runtime/command_rules/authorization.rb`
- `lib/hecksagain/bluebook/ir/command.rb`
- `lib/hecksagain/language/bluebook/behavior.bluebook`
- `spec/runtime/authorization_spec.rb`
- new `spec/runtime/act_as_spec.rb`

### Target behavior

When command A invokes command B across a domain or aggregate boundary, A may declare that the downstream invocation is performed as B's required role. Governance decides whether that transition is permitted.

This preserves the invariant that each command has one role while supporting workflows where the initiating actor's organizational role differs from the downstream domain role.

### Ruby DSL direction

Prefer declaration on the cross-command call rather than global role inheritance.

Illustrative syntax:

```ruby
command "RegisterCustomerAccount" do
  role "Customer administrator"
  goal "Open the customer's operating relationship"

  calls "Customers::Customer.Register",
        as: "Customer registrar"
end
```

Or if cross-command execution remains policy-oriented:

```ruby
policy "RegisterCustomerAfterIdentity" do
  on "IdentityRegistered"

  trigger "Customers::Customer.Register",
          act_as: "Customer registrar"
end
```

The exact surface spelling can be chosen after inspecting the existing `trigger` / orchestration DSL. The IR should care about the semantics, not the spelling.

### Suggested IR

A call edge should contain:

```ruby
{
  command: "Customers::Customer.Register",
  act_as: "Customer registrar"
}
```

Do not change the downstream command:

```ruby
command "Register" do
  role "Customer registrar"
end
```

### Runtime execution

Conceptually:

```ruby
Governance.authorize_transition!(
  actor: current_actor,
  from_command: "Identity::RegisterCustomerAccount",
  from_role: "Customer administrator",
  to_command: "Customers::Customer.Register",
  to_role: "Customer registrar"
)

Runtime::Caller.as(role: "Customer registrar") do
  dispatcher.dispatch("Customers::Customer.Register", **args)
end
```

The existing `Caller.as` should be reused rather than replaced.

### Audit envelope

Preserve:

```ruby
{
  actor: "identity-123",
  originating_role: "Customer administrator",
  effective_role: "Customer registrar",
  originating_command: "Identity::RegisterCustomerAccount",
  command: "Customers::Customer.Register"
}
```

The domain event itself may remain business-focused; the execution/evidence envelope can retain the authority chain.

### Acceptance criteria

- A downstream command still validates only its own single role.
- `act_as` changes effective role only for the nested dispatch.
- Caller role is restored after nested dispatch.
- Unauthorized transitions are refused before downstream state mutation.
- Replay does not invoke live Governance decisions; the accepted authority transition is preserved in execution history.
- Reaction dispatch behavior remains isolated from accidental caller inheritance.

### Non-goals

- Do not make `act_as` a general role hierarchy.
- Do not grant a person every command associated with the assumed role.
- Do not add multiple roles to a command.

---

# 3. Governance Bluebook

**Status:** Done (2026-08-07) — `lib/hecksagain/framework/bluebook/governance.bluebook`
(+ `.hecksagon`, Memory-persisted). `RoleAssignment` aggregate: composite
identity `(actor_id, role_name, starts_at)` rather than the sketch's
synthetic `assignment_id` — no UUID adapter exists yet (`§5`), and a real
assignment event is genuinely unique by actor+role+when it started, so
none is needed. `Assign`/`Revoke` commands (`Revoke` sets `ends_at`,
never deletes), one query (`AssignmentsForActor`, does not filter by
`ends_at` — a caller decision, not baked in). The original sketch's
`Hecks.port "Authorization" do operation "CanActAs" ... returns ... end`
doesn't match the real port DSL (`PortOperation` has no `returns` — it's
`attributes` + required `emits`, an anti-corruption boundary, not a
query); `AssignmentsForActor` is an ordinary `query`, the construct that
actually answers "who holds what" — no new DSL surface needed anywhere
in this build. `spec/corpus_spec.rb`/`spec/model_check_spec.rb` extended
with a `FRAMEWORK_MEMBERS` glob (mirrors `GRAMMAR_CHAPTERS`'s flat-file
pattern) so `lib/hecksagain/framework/bluebook/*.bluebook` gets the same
must-load/must-have-a-corpus-script/no-unnamed-model-check-finding
guarantees `examples/*` domains get. `spec/governance_spec.rb` (4
examples) + `spec/corpus/governance.json`, full suite green (1004
examples). Explicitly NOT done here: `§2` (`act_as` wired to a real
`Governance.authorize_transition!` — there is still no hook point in
`CommandRules::Authorization` for this at all, confirmed by reading it;
`refuse_role_mismatch` is a hard-coded `==`), any port/query surface for
OTHER domains to actually call into Governance at dispatch time, and
`§4`/`§5` (Identities, UUID adapter) — `IdentityId` here is Governance's
own owned value object, not a cross-domain reference.  
**Priority:** P0  
**Complexity:** L

### Target

Create a canonical `governance.bluebook` that models organizational authority independently of business domains.

Governance should answer questions such as:

- Which actor occupies a role?
- Which position confers which roles?
- May one role act as another in this context?
- Is a delegation active?
- Does an operation require approval?
- Is separation-of-duties satisfied?

### Ruby example

```ruby
Hecks.bluebook "Governance" do
  vision "Organizational authority is explicit, reviewable, and historically explainable."
  supporting

  aggregate "RoleAssignment" do
    identified_by { assignment_id.value }

    attribute :assignment_id, AssignmentId
    attribute :actor_id, IdentityId
    attribute :role_name, RoleName
    attribute :scope, Scope
    attribute :starts_at, Timestamp
    attribute :ends_at, Timestamp, optional: true

    command "Assign" do
      role "Governance administrator"
      goal "Authorize an actor to perform a responsibility"

      attribute :assignment_id, AssignmentId
      attribute :actor_id, IdentityId
      attribute :role_name, RoleName
      attribute :scope, Scope
      attribute :starts_at, Timestamp
      attribute :ends_at, Timestamp, optional: true

      emits "RoleAssigned"
    end

    command "Revoke" do
      role "Governance administrator"
      goal "Remove organizational authority"

      reference_to RoleAssignment
      emits "RoleRevoked"
    end
  end

  query "AssignmentsForActor" do
    where(actor_id: :actor_id)
  end
end
```

The exact modeling should be driven by current Bluebook capabilities; avoid adding language solely for Governance.

### Implementation hint

Build Governance first as an ordinary Bluebook using current records/aggregates, commands, queries, lifecycles, policies, and ports. Only promote something into the language if Governance cannot express a universal concept without distortion.

Expose Governance to runtime authorization through a port, not a direct dependency on the Ruby implementation.

Example runtime port concept:

```ruby
Hecks.port "Authorization" do
  operation "CanActAs" do
    attribute :actor_id, String
    attribute :from_role, String
    attribute :to_role, String
    attribute :command, String
  end
end
```

### Acceptance criteria

- Business domains can remain unaware of positions and org charts.
- Governance can answer actor → roles.
- Governance can answer role transition (`act_as`) decisions.
- Authority decisions are era-aware and auditable.
- A replacement external IAM/governance adapter can fulfill the same port.

### Non-goals

- Do not put authentication credentials in Governance.
- Do not make Governance own domain-specific role names.
- Do not add ACL strings as source-of-truth permissions.

---

# 4. Identities Bluebook

**Status:** Done (2026-08-07) — `lib/hecksagain/framework/bluebook/identity.bluebook`
(+ `.hecksagon`, Memory-persisted; chapter renamed from `Identities` to
`Identity` on 2026-08-08, matching Governance's own singular naming —
the aggregate inside is ALSO named `Identity`, so its FQN is the
slightly repetitive but unambiguous `Identity::Identity`). Attached to
Banking for real via `uses_framework "Identity"` in
`examples/banking/bluebook/banking.hecksagon`, the same mechanism
Governance uses — see `§31`'s own note on `Hecksagain::Framework`.
`Identity` (identity_id minted via `§5`'s
`Ports::IdentityGeneration.uuid` — no natural key exists for "a newly
recognized identity," and this is the first real consumer of that
port) and `ExternalIdentifier` (issuer/subject pair, natural key
`key.value`). One correction to the sketch: `ExternalIdentifier` uses a
real `reference_to Identity` rather than a bare owned value object —
both aggregates share one bluebook (unlike Governance's `actor_id`,
which deliberately avoided a cross-domain reference to this exact
domain before it existed), so there's no reason to give up
`resolve_references`'s real existence-checking; `spec/identity_spec.rb`
confirms `Link` refuses against a nonexistent identity, not just that
it succeeds against a real one. `key`'s derivation (SHA256 of
issuer+subject, or any other scheme) stays a caller-side concern, per
the original sketch's own framing — no new port for it.
`spec/corpus_spec.rb`/`spec/model_check_spec.rb` needed no changes —
`§3`'s `FRAMEWORK_MEMBERS` glob picked this domain up automatically.
Full suite green (1019 examples). Explicitly not done: any OIDC
verification (`§11`); Governance's `actor_id` was not retrofitted to
reference this domain.  
**Priority:** P0  
**Complexity:** M

### Target

Create `identities.bluebook` as the domain that relates authenticated identifiers to stable organizational identities. It should not become a junk-drawer `User` model.

The domain should support external identities such as OIDC issuer/subject pairs and locally minted identity IDs where there is no derivable identity.

### Ruby example

```ruby
Hecks.bluebook "Identities" do
  vision "Authentication proves an identifier; the organization decides what that identity means."
  supporting

  aggregate "Identity" do
    identified_by { identity_id.value }

    attribute :identity_id, IdentityId

    value_object "IdentityId" do
      attribute :value, String
      invariant("an identity id is present") { !value.to_s.empty? }
    end

    command "Register" do
      role "Identity registrar"
      goal "Recognize an identity"

      attribute :identity_id, IdentityId
      emits "IdentityRegistered"
    end
  end

  aggregate "ExternalIdentifier" do
    identified_by { key.value }

    attribute :key, ExternalIdentifierKey
    attribute :identity_id, IdentityId
    attribute :issuer, Issuer
    attribute :subject, Subject

    command "Link" do
      role "Identity registrar"
      goal "Associate an external authenticated subject with an identity"

      attribute :key, ExternalIdentifierKey
      attribute :identity_id, IdentityId
      attribute :issuer, Issuer
      attribute :subject, Subject

      emits "ExternalIdentifierLinked"
    end
  end
end
```

### Derived IDs

For OIDC, the external identifier key can be derived deterministically from `(issuer, subject)`.

Example conceptual adapter-side derivation:

```ruby
key = Digest::SHA256.hexdigest("#{issuer}\0#{subject}")
```

The Bluebook need not know how it is derived if the adapter supplies it.

### Acceptance criteria

- An identity can be linked to multiple external identifiers.
- No password is required for OIDC-only deployments.
- Customer/People/User domains can reference Identity without being owned by Identity.
- External provider names do not leak into business domains.

### Non-goals

- No customer preferences.
- No employment data.
- No billing data.
- No authorization policy beyond identity registration/linking.

---

# 5. UUID adapter and imperative enrichment

**Status:** Done (2026-08-07) — `lib/hecksagain/ports/identity_generation.{port,rb}`,
modeled on `Ports::Extraction` (one adapter registry-wide implements the
port; zero/many both refuse), not on Persistence's heavier per-aggregate
binding — different aggregates have no real reason to want different
id-generation strategies. Two adapters: `SecureRandomIdentity` (real)
and `SequentialIdentity` (deterministic, for specs — satisfies the
"replaceable by deterministic test adapter" criterion directly). The
sketch's `operation "UUID" do returns String end` doesn't match the
real port DSL (no `returns` anywhere — same correction `§3` already
needed for its own port sketch); the real precedent for "call something
and get a plain value back" is `extraction.port`'s shape, not
`DomainPort`/`PortOperation`'s. **The "replay never invokes it" half
needed no new mechanism at all** — confirmed by reading the real replay
path (`Fuzzing::Replay` re-dispatches recorded `args` through the
identical `CommandInterpreter` pipeline; nothing ever adds a key to
`args` between a caller and `hydrate`), so a UUID minted for a creating
command's identity is just an ordinary string baked into that step's
own recorded `args` from the moment it's generated — replaying those
args never touches the adapter again, for the same reason
`Event#occurred_at`'s own `Time.now` call (the one existing
"environmental fact" precedent) needs no suppression either. Verified
directly, not just architecturally: `spec/ports/identity_generation_spec.rb`
mints an id, dispatches a real `Pizzas::Order.CreatePizza` with it,
then replays the same recorded args through a fresh boot and confirms
both the identical id and that `SequentialIdentity`'s own counter did
not advance a second time. No `CommandInterpreter`/`Dispatcher`
changes, no new `.hecksagon` binding syntax. Not done: facade-level
automatic enrichment (omitting an identity argument and having a
generated command method fill it in) — demonstrated as an explicit
caller-side call, deliberately not built as new `AggregateDoor` codegen;
nothing in the existing corpus was retrofitted to use this (natural
keys remain preferred wherever one exists).  
**Priority:** P0  
**Complexity:** S–M

### Current correlation

Hecks already has named ports and adapters and a deterministic replay model. `DeclarationSnapshot` demonstrates the strong separation between authoring and replay: structured IR can be reconstructed without rerunning Ruby source.

### Target

When a creating command has no natural/derived reference, the runtime obtains a UUID through an adapter on first execution and freezes it into durable history. Replay never invokes the UUID adapter.

Bluebook remains declarative. UUID generation is an imperative environmental fact.

### Ruby authoring example

Do **not** add a `create` keyword:

```ruby
command "Register" do
  role "Identity registrar"
  goal "Recognize a new identity"

  attribute :identity_id, IdentityId
  emits "IdentityRegistered"
end
```

A façade may allow omission:

```ruby
identities.identity.register
```

and the runtime enriches the command:

```ruby
dispatcher.dispatch(
  "Identities::Identity.Register",
  identity_id: { value: uuid_adapter.generate }
)
```

### Port sketch

```ruby
Hecks.port "IdentityGeneration" do
  operation "UUID" do
    returns String
  end
end
```

If the existing port DSL does not support `returns`, use the existing operation-output convention instead of expanding syntax.

### Runtime rule

```text
first execution:
intent → enrich imperative facts → execute → record facts/events

replay:
recorded facts/events → rebuild state
```

### Acceptance criteria

- UUID adapter called exactly once for first creation.
- Same history replays without UUID adapter.
- Fuzz/replay tests show stable IDs.
- UUID generation is replaceable by deterministic test adapter.
- No UUID library is referenced from Bluebook domain code.

### Non-goals

- Do not force UUIDs where a stable natural identity exists.
- Do not generate IDs inside aggregate IR.
- Do not call UUID adapters during replay.

---

# 6. `report` as business-facing read model

**Status:** Existing `query` + `read_model`; naming change only  
**Priority:** P0  
**Complexity:** XS–S

### Current correlation

Hecks already has both `query` and `read_model`. The query/read-model guide explicitly describes read models as report-like cross-aggregate projections.

### Target

Introduce `report` as the SME-facing spelling for `read_model`, preserving `read_model` as a permanent compatibility alias.

Do not replace `query`. A query is a request/question; a report is a declared view.

### Ruby example

Current:

```ruby
read_model "ComplianceDashboard" do
  reference_to Account
  include Account
  include CardPayment
  where(status: "disputed")
  order_by :amount, :desc
  limit 5
end
```

Preferred:

```ruby
report "ComplianceDashboard" do
  description "One account and the disputed payments requiring review."

  reference_to Account
  include Account
  include CardPayment

  where(status: "disputed")
  order_by :amount, :desc
  limit 5
end
```

Keep:

```ruby
query "SuspendedCustomers" do
  where(status: "suspended")
end
```

### Implementation hint

Make the DSL builder dispatch both words to the same IR type initially. Update self-hosted syntax vocabulary using the existing rename/`was:` mechanism if appropriate so old eras remain valid.

### Acceptance criteria

- `report` and `read_model` produce identical IR.
- Existing Bluebooks boot unchanged.
- Documentation uses `report` as primary business term.
- Golden/corpus tests prove round-trip parity.

### Non-goals

- Do not create a second report runtime.
- Do not conflate report with query.
- Do not add presentation layout to the domain yet.

---

# 7. Canonical IR as durable source format

**Status:** Done (2026-08-07) — `IR::Bluebook::IR_VERSION` (currently `1`) is now the first key `to_h` emits, distinct from a domain's own `version:`; golden IR (all 9 fixtures) and `running-a-runtime.md` updated; `Assembly` needed no change (an unrecognized key is simply not read back). Otherwise strongly present already through `to_h`, `Projector::Exporter`, `DeclarationSnapshot`, `Assembly`.  
**Priority:** P0  
**Complexity:** M

### Current correlation

`Projector::Exporter` serializes booted Bluebooks to hashes/JSON. `Runtime::DeclarationSnapshot` reconstructs a real Bluebook from JSON through `Bluebook::Assembly`. Era replay explicitly no longer depends on reparsing Ruby source.

This is the foundation for language-independent projections.

### Target

Formalize canonical IR as a versioned contract that can be consumed without Ruby authoring. Ruby remains a high-quality authoring surface, but the IR is sufficient to reconstruct and project a Bluebook.

### Ruby generation example

```ruby
registry = Hecksagain.registry
json = Hecksagain::Projector::Exporter.json(registry)
File.write("payments.ir.json", json)
```

### Round-trip invariant

```ruby
original = registry.bluebook("Payments")

json = Hecksagain::Runtime::DeclarationSnapshot.dump(original)
restored = Hecksagain::Runtime::DeclarationSnapshot.load(json)

expect(restored.to_h).to eq(original.to_h)
```

### Implementation hint

Add an explicit top-level IR metadata envelope if one does not already exist:

```ruby
{
  ir_version: 1,
  bluebook: { ... }
}
```

Avoid changing the semantic tree merely to satisfy a projection language. Language projection layers should transform canonical IR into target-specific IR.

### Acceptance criteria

- Canonical IR schema is documented.
- Every supported construct round-trips.
- IR version is explicit.
- Projection tools can operate from an IR file without loading the Ruby DSL.
- Golden corpus covers canonical IR stability.

### Non-goals

- Do not make humans edit canonical IR by hand.
- Do not encode target-language details into canonical IR.
- Do not make JSON formatting itself semantically meaningful.

---

# 8. Rust projection — built, on a different architecture than planned below

**Status:** Substantially done for Pizzas and Banking (zero generation skips on either, as of `feat/rust-projection`'s current tip), on a DIFFERENT architecture than this section originally specified — see "What actually got built" below before reading anything past it as current. No differential-harness integration, no era support, no WASM.  
**Priority:** P0 (was; largely satisfied)  
**Complexity:** XL (was)

### What actually got built

Recorded formally as `docs/decisions/0011-rust-compiles-types-interprets-dispatch.md`, which supersedes `0007`'s central claim — read it for the fuller argument and consequences; this section is the summary.

Everything below this point in §8, up through the original "Non-goals for milestone 1," was written before work started and describes a design that was **not** the one implemented. The as-built system inverts one of that design's own stated non-goals — worth reading as a real correction, not a footnote:

**Location.** `rust/` at the repo root (a Cargo crate — renamed twice in review, first from the pre-existing `rust_runner/`, then settled here specifically so Ruby generator code doesn't live under `lib/hecksagain/`) holds both the Rust crate (`rust/src/`) and its Ruby generator (`rust/project.rb` + `rust/project/*.rb`, module `RustProjection`, no `Hecksagain::` namespace — it's tooling *for* hecksagain, not part of the library). `bin/project_rust <domain>` is the thin driver.

**Architecture actually built: compile types, interpret dispatch DATA.** `rust/src/kernel/{expr.rs,dispatch.rs}` is hand-written **once**, and is a small, fully generic interpreter: `interpret(expr, ctx)` walks an `Expr` AST (a direct structural port of `Evaluator`/`Resolver`'s node kinds — `Or`/`And`/`Not`/`Compare`/`Include`/`Lookup`/arithmetic/sign-test/etc.), and `dispatch(...)` walks the real `DISPATCH_ORDER` steps generically, driven by whatever `GivenSpec`/`EnsuresSpec`/mutation-closure a generated function hands it. This is the **opposite** of the non-goal this section originally stated ("No generic kernel that parses or interprets canonical IR at runtime") — `given`/`ensures`/invariant text genuinely is walked as data, by one hand-written interpreter, at the compiled binary's own runtime. What IS compiled ahead of time, by `bin/project_rust`, is narrower than originally planned: just the **type shapes** — real Rust structs/enums per value object/entity/record, plus a `Fielded` trait impl per type so the generic interpreter can do name-based field lookup (`"balance.cents"`) against otherwise fully static, typed data. The generator itself parses real IR objects via Ruby's own `Evaluator.parse`, then emits `Expr::Compare { ... }`-shaped Rust *data literals*, not compiled boolean expressions.

Why this diverged: mid-build, generating one bespoke Rust function per command *shape* (a plain creator vs. an acting command with a given vs. one with a lifecycle transition vs. one with `ensures`...) didn't converge — every new shape needed a new hand-written case, the same failure mode this section already correctly diagnosed for the *retired* Rust runtime, just one level down (per-shape codegen instead of a whole second interpreter). Interpreting dispatch data generically, once, was the fix — see `docs/guides/running-a-runtime.md`'s "Interpret data, don't compile source" section for the fuller argument.

**What generates correctly today, for both Pizzas and Banking, zero skips:** every `then_set` op (`set`/`append`/`increment`/`decrement`, including cross-VO-type coercion by matching field names — `Value::Coercion#fields_for`'s real rule, not a guess), `given`/`ensures` (any expression the real grammar admits — no `Unsupported` case, because an interpreter needs none of the static machinery a compiler would), lifecycle transitions, closed sets (including multi-field ones, as a data table rather than a tag enum), composite identity (dotted, bare-declared, and bare-undeclared components), and **entities** — a capability this section didn't originally scope at all: `list_of(Entity)` attributes (`Account.ledger`, a `Vec<LedgerEntry>`) are a valid `append` target, with the entity's own identity and lifecycle field auto-filled at append time the way `MutationApplier#entity_element` fills them. The self-hosted grammar itself (`lib/hecksagain/language/bluebook/`) also compiles through the identical pipeline, alongside whichever business domain is the build target — another capability not in the original plan.

**What's still real and unbuilt, same as before:** an entity's OWN commands (`LedgerEntry.Amend`/`.Reverse` — addressing one list element by identity, a materially different and larger feature); role checking; reference-existence checking (`resolve_references`); era selection / historical-era support (the current generator only ever targets a domain's *current* declared shape — there is no era concept in it at all, a bigger gap against this section's original semantic requirement than "not yet optimized," genuinely not attempted); WASM (`§9`, fully unstarted, and now depends on a different underlying design than `§9` assumes — see `§9`'s own note).

**Verification, as actually done:** `bin/rust_conformance` (restored 2026-08-07 alongside this document, confirmed still running against the current codebase — `spec/corpus/pizzas.json` and `banking.json` both still work) was **not** wired into the Rust generator's workflow at any point. Everything above was verified instead by direct `cargo run` smoke tests against real scenarios (`Account.Open → Credit → Debit → over-limit refusal`, `ScheduledPayment.Schedule → Fail → Retry ×3 → exhausted`, the full Pizzas walkthrough), diffed by eye against known-correct Ruby behavior, plus `spec/port_shape_coverage_spec.rb` (a Ruby-side gate ensuring Banking keeps exercising every IR shape the generator branches on) and full-suite regression on the Ruby side after every change. Wiring `bin/rust_conformance` into an automated per-change check against the Rust output remains real, valuable, un-started work — see "If this is picked up again," below.

Everything from here to the end of §8 is the **original plan**, kept verbatim as a record of the intended design — read it as history, not as a spec to implement, except where the notes above say otherwise.

### Original target (superseded — see above)

Rust is a **projection**, not an interpreter, and specifically a *code generator*, not a data embedder: a build-time tool reads canonical IR and emits native Rust source — types for records/value objects, a dispatch table, and per-command argument gates, role checks, `given` evaluation, mutation application, and event emission, all as real generated Rust code. That generated code is what gets compiled. A small hand-written kernel supplies only genuinely domain-independent infrastructure (the repository trait, evaluator primitives the generated `given` code calls into, the dispatch entry point) and is compiled alongside the generated code. Ruby is not required at runtime, and neither is the IR file; both are authoring/build-time-only.

The governing invariant is narrower than "nothing IR-shaped exists in the binary": **no canonical IR is parsed or interpreted at runtime — runtime behavior is compiled into native code.** That leaves room for the generator to also emit compact static metadata tables (for introspection, evidence, diagnostics, docs, or explaining a refusal) without reopening the interpreter architecture, as long as those tables are consulted for *description*, not walked by a generic kernel to *decide* behavior. Behavior comes from generated code paths; metadata is only ever read, never interpreted.

**The semantic requirement is that the compiled artifact can execute or query any held era, not a snapshot of current semantics only** — matching Ruby's era-replay capability (`§25`), not a reduced "current era only" subset. That requirement is separate from how eras get generated, and shouldn't be read as committing to a specific implementation forever.

*Initial implementation:* one generated module per held era. The codegen step reads every held declaration for the Bluebook (the same lineage `DeclarationSnapshot`/`era_check` machinery Ruby's history tooling already uses) and generates a module per era — its own types, dispatch table, and command logic — with a single dispatch entry point that takes an era selector (defaulting to the latest) and routes into the matching module. This is the simplest thing that satisfies the semantic requirement, and it's an explicit **scaling concern, not a permanent architecture**: a long-lived domain with many eras where most rules are unchanged from one era to the next would generate and compile a full duplicate module per era regardless. Don't let the wording here — or the milestone-1 acceptance criteria below — foreclose a later optimization that deduplicates unchanged behavior across eras (e.g. sharing generated functions/types where two eras' declarations produce identical output, and only forking where they diverge); that's a code-generator-internals improvement, not a semantic change, and shouldn't require touching this section's acceptance criteria to land.

The real constraint regardless of implementation: minting a *new* era still requires rerunning codegen and recompiling — the compiled artifact does not ingest a new era at runtime, by the same no-runtime-IR design as everything else in this section.

Minimum path:

```text
Ruby DSL (authoring only)
      ↓
canonical Bluebook IR for every held era (JSON, build-time artifact — consumed once, then discarded)
      ↓
Rust projection (code generator; initial implementation: one module per held era)
      ↓
generated Rust source — native types & per-command logic derived from the IR, per era
      ↓
compiled together with a small hand-written shared kernel + an era-dispatching entry point
      ↓
native binary / library / WASM — every held era's semantics compiled in as code, not carried as embedded IR data
```

### Ruby authoring remains unchanged

```ruby
Hecks.bluebook "Payments" do
  aggregate "Payment" do
    command "Open" do
      role "Merchant"
      goal "Start tracking a payment"
      emits "PaymentOpened"
    end
  end
end
```

No Rust syntax appears in the Bluebook.

### Original acceptance criteria (superseded — see "What actually got built")

- Milestone 0's differential harness exists, runs against the existing corpus, and is the thing CI/review actually checks — not a one-time manual comparison.
- A compiled Rust binary, generated from canonical IR at build time, boots and executes with no Ruby present and no IR file present; no canonical IR is parsed or interpreted at runtime.
- The compiled binary contains generated command logic (real Rust types and functions) that decides behavior; any generated static metadata (for introspection, evidence, diagnostics, or refusal explanations) is read, never interpreted as instructions.
- The compiled binary can execute or query against any held era of the Bluebook it was generated from, selected at dispatch time — not current-era semantics only.
- Minting a new era requires rerunning codegen and recompiling; no era is added to a running binary.
- Pizzas and a minimal Banking subset execute in Rust across at least two held eras each, with the harness green for both.
- Rust outputs same accepted/refused behavior for chosen corpus cases, per era, per the harness — not spot-checked by hand.
- No Ruby parser is ported.
- No Ruby DSL builder is ported.
- New Bluebook syntax affecting canonical IR requires little or no handwritten Rust parsing work.

### Original non-goals (superseded — the as-built system violates the interpreter one on purpose; see above)

- No Rust authoring DSL. *(still true)*
- No Postgres. *(still true)*
- No Rails compatibility. *(still true)*
- No full parity corpus. *(still true — no differential harness integration exists)*
- No hand-written Ruby source parser. *(still true)*
- No generic kernel that parses or interprets canonical IR at runtime — the generator emits real code that decides behavior; nothing walks IR-shaped data to figure out what to do. *(FALSE as built — see "What actually got built": this is exactly what the hand-written kernel does, deliberately, and it's why the generator converged)*
- No runtime era minting — new eras are a recompile, not a live update. *(moot — there is no era concept in the as-built generator at all)*

### If this is picked up again

Real, scoped next increments, roughly in order of how self-contained each is: (1) `bin/rust_conformance`'s `native`/`<path.wasm>` subprocess mode ([0012](decisions/0012-wasm-via-wasi-stdio.md)) is now wired into CI as an automated regression gate (`spec/rust_conformance_spec.rb`, run by the same `bundle exec rspec` CI already runs) — **done**; (2) entity commands (`Amend`/`Reverse`-shaped — addressing one list element by its own identity) — **done** ([0013](decisions/0013-rust-generates-entities-policies-sagas.md)), along with policies and process managers/sagas, neither of which this section originally scoped at all; (3) the JSON-boundary `refuse_unknown_arguments`/`refuse_absent_arguments` equivalent 0013 flagged — **done** ([0014](decisions/0014-rust-json-boundary-argument-checking.md)) — and the `optional: true`/`Option<T>` modeling gap 0014 found and deferred — **done** ([0016](decisions/0016-rust-option-wraps-optional-attributes.md), skips loudly the one shape it can't honestly represent: an optional argument feeding a non-optional VO/entity field); role checking and reference-existence checking remain deferred, the latter still explaining the "only in native" extra records a real corpus run produces; (4) era support, which needs real design work first (the as-built generator has no concept of "which era" at all — this isn't a missing feature so much as an unaddressed dimension); (5) `§9` WASM — a first, non-browser slice shipped ([0012](decisions/0012-wasm-via-wasi-stdio.md), stdin/stdout over WASI, not the JS API), plus a browser wasm-bindgen slice ([0015](decisions/0015-wasm-bindgen-browser-projection.md)); the original browser-facing design in `§9` remains only partially scoped against the as-built (no-era) architecture.

---

# 9. WASM embedded Bluebook

**Status:** A first WASM slice is built, on a DIFFERENT shape than this section originally specified — see [decision 0012](decisions/0012-wasm-via-wasi-stdio.md) and "What actually shipped" below. Everything else in this section (the browser JS API, per-era dispatch, the host-adapter import boundary) remains unstarted and was written against the ORIGINAL `§8` design; re-scope against the as-built architecture before picking it up, particularly the per-era claims in the acceptance criteria.  
**Priority:** P1  
**Complexity:** L

### What actually shipped (WASI-stdio slice, 0012)

Not the browser JS API below — a stdin/stdout JSON CLI contract (`{"steps": [...]}` in, `{"instances", "events", "refusals"}` out — `bin/rust_conformance`'s own pre-existing shape), compiled unchanged for both native (`aarch64-apple-darwin`) and `wasm32-wasip1` (WASI preview 1). `bin/project_wasm <domain>` regenerates and cross-compiles; `bin/rust_conformance <domain> <script.json> native|<path.wasm>` runs either artifact as a real subprocess and diffs it against the Ruby oracle, finally wiring the subprocess hook that tool's own header comment used to say didn't exist. Verified on Banking (10 aggregates, composite identities, closed-set data tables): `instances` matches byte-for-byte across Ruby, native Rust, and WASM-under-`wasmtime`. Two pre-existing, unrelated fidelity gaps surfaced by actually running the harness live rather than fixed by this slice — `events[].payload`'s debug-string-vs-structured-JSON shape, and a refusal-wording prefix Ruby adds and Rust doesn't — see 0012's own Consequences for both.

No era selection (the generator still has no era concept — §8's own still-open gap, untouched here), no browser JS API, no host-adapter import boundary. The rest of this section — Target through Non-goals — is the ORIGINAL, still-unbuilt browser-facing design; 0012's "Rejected alternatives" explains why it wasn't what got built first, and that a browser layer remains a plausible follow-on built ON TOP of the WASI-stdio contract, not a replacement for it.

### Target

Compile the artifact `§8` generates to WASM so browser applications can call the domain directly as their internal command bus. This is a compile target of `§8`'s single runtime, not a separate implementation.

### JS-facing API target

The Bluebook's command logic — every held era of it — is already compiled into `parcelpro.wasm` by `§8`'s code generator, so loading the module takes no separate IR argument — there is nothing left to load into it:

```javascript
const domain = await Hecks.load("parcelpro.wasm")

await domain.dispatch("LandPlanning::Road.MoveVertex", {
  road_id: "r-1",
  vertex: 3,
  x: 12.2,
  y: 4.8
})
// domain.dispatch(name, args, { era: 12 }) — optional, defaults to latest

const report = await domain.report("LandPlanning::ProjectView", {
  project_id: "p-1"
})
```

### Ruby source remains normal Bluebook

```ruby
command "MoveVertex" do
  role "Designer"
  goal "Move a road vertex"

  reference_to Road
  attribute :vertex, Integer
  attribute :x, Float
  attribute :y, Float

  emits "RoadVertexMoved"
end
```

### Host adapter boundary

Browser-only capabilities remain outside WASM:

- IndexedDB
- files
- networking
- map APIs
- rendering
- authentication tokens

Define narrow imported host operations rather than embedding JS application code in the runtime.

### Acceptance criteria

- WASM module has the Bluebook's command logic compiled in at build time, across every held era; no IR is loaded, parsed, or shipped to the browser at runtime.
- UI can dispatch commands directly without HTTP.
- Local read/report output updates synchronously or predictably.
- State can be externalized and restored across module replacement.
- Hot update is module replacement + state reattachment, not unsupported live-code mutation.

### Non-goals

- No UI framework in Bluebook.
- No DOM manipulation in runtime.
- No browser-specific semantics in canonical IR.

---

# 10. SQL projection vs SQL runtime

**Status:** Persistence projections already exist implicitly in adapters; full runtime is research  
**Priority:** P2  
**Complexity:** L–XL

### Target A — SQL artifact projection

Separate schema/migration generation conceptually from persistence execution.

```text
Bluebook IR → Postgres DDL / SQLite DDL
```

### Target B — executable Postgres projection

Research compiling transactional command semantics into stored procedures, constraints, triggers, and views.

Ruby Bluebook:

```ruby
command "CloseAccount" do
  role "Branch clerk"
  reference_to Account

  given("the balance is zero") { balance.cents == 0 }

  emits "AccountClosed"
end
```

Possible generated PostgreSQL surface:

```sql
select * from banking_close_account(
  actor_id => 'a-1',
  account_number => '1234'
);
```

### Keep outside SQL

- HTTP calls
- Stripe
- email
- AI
- long-running workflows

Use outbox/ports for those.

### Acceptance criteria for research spike

- One simple aggregate command executes atomically in Postgres.
- `given` refusal wording remains equivalent.
- event/evidence record is written in same transaction.
- generated SQL is inspectable.
- no canonical IR changes required solely for SQL.

---

# 11. OIDC client projection

**Status:** Integration layer done (2026-08-08) — the real provider-
facing half (redirect, code exchange, JWT/JWKS signature verification
against a live provider) is deliberately NOT built: security-critical,
needs real external dependencies and provider credentials neither
available nor meaningfully testable here, scoped out on purpose rather
than stubbed. What IS built and proven against real Banking: a new
`identity_resolution` port (`lib/hecksagain/ports/identity_resolution.{port,rb}`),
resolved zero/one/many exactly like the `authorization` port
`Ports::Authorization` built for `§2`, fulfilled by `Hecksagain::Adapters::IdentityRegistry`
(`lib/hecksagain/adapters/driven/identity_registry.rb`) — a same-registry
dispatch against `Identity::ExternalIdentifier.ResolvedBy`, mirroring
`GovernanceAuthorization`'s own shape exactly. `spec/oidc_projection_spec.rb`
composes it with `Ports::Authorization.holds_role?` and `Hecks.as_caller`
— the plan's own sketch, just spelled out — booted through the real
`Hecks.boot("examples/banking")` path (both Governance and Identity are
already attached there via `uses_framework`, see `§4`/`§5`'s own notes).
Every acceptance criterion below is proven, not merely asserted: no
password field exists on `Identity`/`ExternalIdentifier` (checked
against the real declared attributes), `(issuer, subject)` uniquely
resolves (checked against `Link`'s own natural key), two different
external identifiers link to one identity and both authenticate
(dispatched for real, against real Banking commands), and the
unauthorized/unresolved paths refuse BEFORE any dispatch — command
authorization stays exactly Governance's job, `identity_resolution`
never touches `CommandInterpreter`/`Dispatcher`/`CommandRules::Authorization`.  
**Priority:** P1  
**Complexity:** M

### Target

Allow applications to authenticate through Google/Microsoft/etc. as OIDC clients while mapping `(issuer, subject)` into `identities.bluebook`.

### Flow

```text
OIDC provider
→ verified issuer/subject
→ identities.bluebook lookup/link
→ stable Identity
→ Governance roles
→ command dispatch
```

### Ruby application integration sketch

```ruby
identity = identities.lookup_external(
  issuer: claims["iss"],
  subject: claims["sub"]
)

Hecks.as_caller(role: governance.role_for(identity)) do
  runtime.dispatch("Billing::Invoice.Refund", **args)
end
```

This is illustrative; final runtime should carry actor separately from role.

### Acceptance criteria

- No passwords stored.
- `(issuer, subject)` uniquely identifies external login.
- Multiple external identifiers may link to one internal identity.
- command authorization remains domain/governance responsibility.

---

# 12. OIDC provider projection

**Status:** New executable protocol projection  
**Priority:** P2  
**Complexity:** XL

### Target

Project Identity + Governance into a deployable OIDC provider that exposes standard endpoints while Bluebook remains the organizational source.

Expected generated/hosted surfaces:

```text
/.well-known/openid-configuration
/authorize
/token
/jwks.json
/userinfo
```

### Bluebook source idea

```ruby
Hecks.bluebook "IdentityProvider" do
  # business configuration represented with normal Bluebook concepts
end
```

Protocol machinery should be projection/runtime code, not DSL keywords.

### Runtime configuration

Issuer URL, signing keys, upstream providers, registered clients, redirect URIs, token lifetimes, and storage remain deployment configuration/adapters.

### Acceptance criteria

- Standard OIDC client can authenticate against generated provider.
- Governance supplies organizational role claims where configured.
- keys rotate without changing Bluebook.
- protocol tests use conformance suites where possible.

---

# 13. Email OTP adapter

**Status:** New auth adapter  
**Priority:** P1  
**Complexity:** M

### Target

Provide passwordless email sign-in as an alternative authenticator feeding `identities.bluebook`.

### Domain flow

```ruby
command "RequestLoginCode" do
  role "Anonymous"
  goal "Prove control of an email address"
  attribute :email, EmailAddress
  emits "LoginCodeRequested"
end
```

The actual random code generation and email send are adapters. The durable domain should store only appropriate digests/state required to verify the challenge.

### Acceptance criteria

- Codes are single-use.
- Expire.
- Rate limited.
- Stored as digest, not plaintext.
- Authentication resolves to Identity.
- No downstream command treats OTP as authorization.

---

# 14. People / Customers / Users decomposition

**Status:** Canonical corpus design  
**Priority:** P1  
**Complexity:** M

### Target

Keep technical identity separate from business identity.

Potential canonical Bluebooks:

```text
identities.bluebook — who can be authenticated
people.bluebook     — people/teams/employment
customers.bluebook  — commercial relationships
users.bluebook      — app-specific preferences, only if needed
governance.bluebook — authority
```

### Ruby relationship example

```ruby
Hecks.bluebook "Customers" do
  aggregate "Customer" do
    identified_by { customer_id.value }

    reference_to "Identities::Identity", as: :identity_id, optional: true

    attribute :customer_id, CustomerId
    attribute :identity_id, IdentityId, optional: true
  end
end
```

Use the actual cross-domain reference mechanism supported by Hecks; the syntax above is illustrative if FQN references require adjustment.

### Acceptance criteria

- Customer can exist without login.
- Identity can exist without customer.
- Employee can have multiple authentication identities.
- User preferences do not contaminate identity or governance.

---

# 15. UL Projection

**Status:** New projection class  
**Priority:** P0  
**Complexity:** L

### Target

Adapt a canonical Bluebook into an organization's ubiquitous language while preserving executable semantics.

Example canonical source:

```ruby
command "Refund" do
  role "Refund agent"
end
```

UL mapping:

```ruby
Hecks.ul_projection "Acme Payments" do
  role "Refund agent", as: "Customer success representative"
  command "Refund", as: "Reverse charge"
end
```

Projected Bluebook:

```ruby
command "Reverse charge" do
  role "Customer success representative"
end
```

The exact mapping DSL can live in a supporting Bluebook or projection configuration rather than core Bluebook grammar.

### Critical invariant

The projection changes vocabulary, not behavior.

`given`, `ensures`, lifecycle transitions, mutation semantics, types, and event relationships remain equivalent unless onboarding explicitly records a semantic customization.

### Implementation hint

Start by operating directly on canonical IR hashes:

```ruby
projected = ULProjector.call(ir, mapping)
```

Do not parse/rewrite Ruby source.

Then render projected IR back to Bluebook source if human-editable output is desired.

### Acceptance criteria

- Role rename propagates to all affected command role references.
- Command rename updates all semantic edges targeting that command.
- Record rename updates references.
- Projection does not alter rules/mutations.
- Projected IR validates through normal `Bluebook::Assembly`.
- Resulting Bluebook can become independent source of truth.

---

# 16. UL adoption recipe

**Status:** New durable supporting artifact  
**Priority:** P0  
**Complexity:** M

### Target

Keep the UL projection used during onboarding so future canonical releases can be adapted again without repeating all mappings.

Example recipe:

```ruby
Hecks.ul_projection "Acme Payments" do
  from "Embryonaut::Payments", version: "1.2"

  role "Refund agent", as: "Customer success representative"
  role "Payment processor", as: "Finance administrator"

  command "Cancel refund" do
    role "Finance manager"
  end
end
```

This recipe is **not** required at runtime.

### Acceptance criteria

- Recipe can be replayed against a newer canonical version.
- Missing new concepts are reported explicitly.
- Existing organization Bluebook can diverge after adoption.
- recipe retains provenance to canonical source/version.

---

# 17. Onboarding Bluebook

**Status:** New supporting Bluebook  
**Priority:** P0  
**Complexity:** L

### Target

Model ontology adoption as a business process using Hecks itself.

Suggested aggregates:

- Adoption
- MappingDecision
- Conflict
- Recommendation
- CanonicalSource

Suggested commands:

- BeginAdoption
- MapRole
- MapRecord
- MapCommand
- ReassignCommandRole
- AcceptProjection
- UpgradeAdoption
- ResolveConflict

Suggested reports:

- UnmappedConcepts
- CommandsAffectedByRole
- AdoptionProgress
- UpgradeImpact
- Conflicts

### Ruby sketch

```ruby
Hecks.bluebook "Onboarding" do
  supporting

  aggregate "Adoption" do
    identified_by { adoption_id.value }

    command "MapRole" do
      role "Domain owner"
      goal "Express a canonical responsibility in our language"

      reference_to Adoption
      attribute :canonical_role, String
      attribute :organization_role, String

      emits "RoleMapped"
    end
  end

  report "UnmappedRoles" do
    # driven from stored adoption state
  end
end
```

### Adapter needs

Onboarding must inspect external Bluebook IR, so define a projection/catalog port rather than letting the Bluebook read files directly.

### Acceptance criteria

- Can inspect a canonical Bluebook.
- Can inspect organization Bluebooks.
- Can enumerate roles.
- Can persist mapping decisions.
- Can request a UL projection.
- Can present affected commands before acceptance.

---

# 18. Role mapping review

**Status:** New onboarding feature  
**Priority:** P0  
**Complexity:** M

### Target

When the organization maps a canonical role, show every command that will inherit the mapping before writing the projected Bluebook.

Example:

```text
Refund agent → Customer success representative

Affected:
- Refund payment
- Review refund
- Cancel refund
- View refund history
```

SME may then override one:

```text
Cancel refund → Finance manager
```

### Representation

Store mapping at two levels:

```ruby
role_mapping "Refund agent" => "Customer success representative"

command_override "Payments::Refund.Cancel",
                 role: "Finance manager"
```

### Acceptance criteria

- UI/report lists all affected commands.
- command-level overrides win over role-level mapping.
- generated Bluebook contains final organization role names directly.
- no runtime ACL translation is required after adoption.

---

# 19. Existing-role discovery

**Status:** New onboarding projection/query  
**Priority:** P1  
**Complexity:** M

### Target

Onboarding should inspect organization Bluebooks and offer existing roles as mapping choices.

Potential sources:

- governance.bluebook
- people.bluebook
- other installed domain Bluebooks
- imported ACL/IAM role adapter

### Example output

```ruby
[
  "Customer success representative",
  "Finance administrator",
  "Controller",
  "Operations manager"
]
```

### Acceptance criteria

- Deduplicate role vocabulary.
- Show where each role is currently used.
- Allow "create a new role".
- Mapping choices are references to known organization concepts where possible.

---

# 20. Semantic mapping suggestions

**Status:** New AI-assisted tool; optional  
**Priority:** P2  
**Complexity:** L

### Target

Rank likely organization-role matches based on command/responsibility shape rather than string similarity alone.

Example:

```text
Canonical Refund Agent:
  Refund payment
  Review refund
  View payment

Matches:
  Customer Success Representative  0.92
  Finance Administrator            0.71
```

### Implementation hint

Create semantic feature vectors from canonical IR:

- commands owned
- records touched
- goals
- events
- policies
- neighboring roles

AI proposes; SME approves.

### Non-goal

Never silently apply authority mappings based on AI confidence.

---

# 21. Semantic drift detection

**Status:** Existing era/translation/diff machinery is a foundation; broaden scope  
**Priority:** P1  
**Complexity:** L

### Current correlation

Hecks already has:

- era shape diff
- translation audit
- canonical form
- history/evolve tooling
- held declarations
- reattestation
- tamper detection

### Target

Define drift as disagreement between semantic representations, not textual differences.

Drift pairs:

```text
Canonical Bluebook ↔ Organization Bluebook
ISO mapping        ↔ Bluebook
Bluebook           ↔ projected artifacts
Era N              ↔ Era N+1
```

### Agent API direction

```ruby
diff = Hecks::SemanticDiff.call(old_ir, new_ir)

diff.commands.changed
diff.roles.renamed
diff.rules.changed
diff.references.changed
```

### Acceptance criteria

- Renames are distinguished from delete+add where provenance exists.
- rule changes are surfaced separately from vocabulary changes.
- affected commands/reports/standards are traversable.
- diff can feed onboarding and upgrade reports.

---

# 22. Canonical ontology upgrades

**Status:** New workflow built on UL Projection + drift  
**Priority:** P1  
**Complexity:** XL

### Target

Upgrade an organization from canonical v1 to canonical v2 without overwriting organization-specific evolution.

Conceptual three-way merge:

```text
canonical v1
      ↓ UL recipe
projected org baseline v1
      ↓ org edits
organization current

canonical v2
      ↓ same UL recipe
projected org candidate v2

semantic merge(candidate v2, organization current, baseline v1)
```

### Acceptance criteria

- Pure canonical additions merge automatically where unambiguous.
- new unmapped roles become onboarding tasks.
- customer changes are preserved.
- overlapping semantic changes become explicit conflicts.
- accepted upgrade creates a new Era.

---

# 23. ISO discovery and projection

**Status:** New adjacent workflow  
**Priority:** P2  
**Complexity:** XL

### Target

Use ISO standards as discovery inputs for executable quality/compliance Bluebooks. Initially humans interpret requirements into Bluebook; later an ISO-facing projection provides clause coverage and documentation.

Do not make ISO a new Bluebook dialect.

### Ruby example

```ruby
Hecks.bluebook "QualityManagement" do
  aggregate "Nonconformity" do
    command "Report" do
      role "Quality representative"
      goal "Record a failure to meet a requirement"
      emits "NonconformityReported"
    end
  end

  aggregate "CorrectiveAction" do
    command "VerifyEffectiveness" do
      role "Quality manager"
      goal "Confirm the corrective action solved the problem"
      emits "CorrectiveActionVerified"
    end
  end
end
```

### Traceability metadata

Prefer external mapping initially:

```ruby
map "ISO9001:2015/10.2",
    to: [
      "QualityManagement::Nonconformity.Report",
      "QualityManagement::CorrectiveAction.VerifyEffectiveness"
    ]
```

### Acceptance criteria

- Every mapped standard requirement can list implementing Bluebook concepts.
- Bluebook change can report impacted clauses.
- standard revision can report impacted Bluebook concepts.
- generated conformance report is reproducible from Bluebook + mapping.

---

# 24. Standards conformance drift

**Status:** New  
**Priority:** P2  
**Complexity:** L

### Target

If a Bluebook changes in a way that invalidates its ISO mapping, create a reconciliation task instead of silently generating stale documentation.

Example:

```text
Changed:
QualityManagement::ReleaseProduct

Potentially affected:
ISO 9001 §8.6

Reason:
approval evidence removed

Resolution required:
- restore behavior
- update mapping
- record justified deviation
```

### Acceptance criteria

- Mapping dependencies are graph edges.
- semantic diff traverses those edges.
- unresolved standard drift is reportable.
- accepted reconciliation is era-versioned.

---

# 25. Historical runtime query by Era

**Status:** Much of the storage foundation already exists  
**Priority:** P1  
**Complexity:** M

### Current correlation

The codebase already stores held era declarations, structured declaration snapshots, resolved era ordinals, shape checks, translations, and replay tooling.

### Target

Expose a simple first-class API to boot/query a historical Era without Git or source checkout.

Ruby target:

```ruby
history = Hecks.at(era: 12, domain: "Banking")

history.query(
  "Banking::Customer.Suspended"
)
```

or:

```ruby
Hecks.query(
  "Banking::Customer.Suspended",
  era: 12
)
```

### Implementation hint

Use held structured declarations (`DeclarationSnapshot`) and the lineage adapter's era data directly. Do not parse historical Ruby source unless a repair/reattest tool explicitly requires it.

### Acceptance criteria

- Query Era N without current Bluebook semantics leaking in.
- read-only by default.
- result identifies Era.
- historical runtime can explain command/rule shape of that Era.

---

# 26. Historical analytics / reports by Era

**Status:** New surface over existing era storage + query/read_model  
**Priority:** P1  
**Complexity:** M

### Target

Let analysts run reports against the semantics of the era in which data was produced, or intentionally restate through current semantics.

Two explicit modes:

```ruby
report.run(era: 12, interpretation: :historical)
report.run(era: 12, interpretation: :current)
```

Historical means "what did this mean then?" Current means "translate old facts forward and answer using today's definition."

### Acceptance criteria

- mode is explicit.
- historical report boots historical IR.
- current restatement uses declared forward translations only.
- no implicit backwards transformation is required.

---

# 27. Data engineering projections from reports

**Status:** Existing query/read-model infrastructure is foundation  
**Priority:** P2  
**Complexity:** L

### Target

Treat analytical artifacts as projections of Bluebook reports instead of standalone warehouse semantics.

Potential targets:

- SQL view
- materialized view
- DuckDB query
- Parquet export
- BI metadata
- CSV

Ruby source:

```ruby
report "MonthlyRevenue" do
  include Invoice
  where(status: "paid")
  order_by :paid_at
end
```

Projection command:

```bash
bin/project MonthlyRevenue --target postgres-view
```

### Acceptance criteria

- analyst-facing report remains source.
- SQL is generated artifact.
- era semantics are retained in output metadata.
- projection can be regenerated.

---

# 28. Canonical corpus

**Status:** New product layer; existing `spec/corpus` proves corpus tooling patterns  
**Priority:** P1  
**Complexity:** Ongoing

### Target

Build a curated repository of canonical Bluebooks that capture reusable organizational knowledge.

Initial candidates:

- Money
- Identity
- Governance
- People
- Customers
- Payments
- Invoicing
- Inventory
- Scheduling
- Audit
- Quality / CAPA

### Quality bar

A canonical Bluebook should include:

- explicit vision
- business vocabulary
- roles
- commands/goals
- events
- policies
- lifecycles
- reports
- fuzz/model-check coverage where consequential
- provenance/research notes

### Non-goal

Do not canonicalize arbitrary application implementation details.

---

# 29. GitHub/documentation pattern discovery

**Status:** Research/product tooling  
**Priority:** P3  
**Complexity:** XL

### Target

Use public source/documentation as evidence for discovering recurring business patterns, then author canonical Bluebooks from those findings.

Pipeline:

```text
sources
→ pattern extraction
→ semantic clustering
→ candidate ontology
→ human/AI review
→ canonical Bluebook
→ verification
```

Do not mechanically translate source code line-by-line.

### Acceptance criteria

- every canonical concept retains provenance/evidence.
- licensing boundaries are respected.
- source patterns are reduced to business semantics rather than copied implementation.

---

# 30. Projector architecture

**Status:** Minimal `Projector::Exporter` exists  
**Priority:** P0  
**Complexity:** M

### Target

Turn `Hecksagain::Projector` into a stable projection framework rather than one exporter module.

Suggested interface:

```ruby
Hecks::Projector.register(:rust, RustProjector)
Hecks::Projector.register(:ul, ULProjector)
Hecks::Projector.register(:openid, OIDCProjector)

Hecks::Projector.call(
  :rust,
  bluebook: ir,
  options: {}
)
```

`RustProjector` here is `§8`'s code generator: this `.call` is the build-time step that emits the native Rust source described there (one module per held era), not a runtime call — its output is source files for the Rust toolchain to compile, the same way `:ul`'s output is a projected Bluebook and `:openid`'s is provider configuration.

### Layers

```text
Canonical IR
→ target normalization
→ target IR
→ renderer/artifact emitter
```

This prevents target formatting logic from polluting canonical semantics.

### Acceptance criteria

- projectors can consume IR without live runtime.
- deterministic output.
- target version metadata.
- projectors test against golden artifacts where appropriate.

---

# 31. Port fulfillment graph

**Status:** Done (2026-08-07) — `lib/hecksagain/runtime/capability_graph.rb`,
`Hecksagain::Runtime::CapabilityGraph`, exposing exactly the sketched
`registry.capability_graph.{fulfillments,unfulfilled,cycles}`. Built off
what the registry already holds: `registry.ports`/`registry.adapters`, and
the same `adapter.port == port.name` match `Ports::Extraction` and
`Ports::IdentityGeneration` already make for themselves, one port at a
time — this asks it once, for every port at once. `cycles` answers `[]`
always, and honestly: nothing in this port model lets one port depend on
another, so there is no edge for a cycle to be made of. `Registry
#capability_graph` is a memoized wrapper, matching `#repository`'s own
pattern one line above it. `spec/runtime/capability_graph_spec.rb` proves
fulfilled/unfulfilled/multi-adapter cases against a real registry (Memory
on persistence, Prism on extraction, identity_generation declared and
left unbound on purpose, to exercise the gap). The onboarding-UI framing
above ("Found: ✓ Acme Governance ○ ...") is not built — this section only
covers the data the UI would read.  
**Priority:** P1  
**Complexity:** M

### Target

Expose the dependency tree that already emerges from port fulfillment.

Example:

```text
Payments
├── Identity → Identities.bluebook
├── Governance → Governance.bluebook
└── PaymentGateway → Stripe.adapter
```

### Agent API

```ruby
graph = registry.capability_graph

graph.unfulfilled
graph.fulfillments
graph.cycles
```

### Onboarding use

When canonical Payments requires a port:

```text
Governance capability required.

Found:
✓ Acme Governance
○ Embryonaut Governance
○ External adapter
```

### Acceptance criteria

- graph generated from declarations/wiring, not package metadata.
- unresolved ports are actionable.
- supporting Bluebooks and adapters appear uniformly as fulfillments.

---

# 32. Business-language audit of DSL

**Status:** Audited (2026-08-07) against the current public keyword list (`spec/dsl_coverage_spec.rb`'s own maintained inventory). Conclusion: `read_model` → `report` (`§6`) was the one concrete, ready-to-execute rename, and it's done. Everything else this section names is a "retain" or an explicitly open "consider," not a decided rename — `aggregate` in particular is real DDD jargon an SME wouldn't naturally reach for, but renaming it would be structural (it's the core keyword, not a leaf verb like `report` was) and the plan itself only ever says "consider," not "do" — left alone on purpose, per "do not rename merely for novelty," not overlooked. `sets`/`then_set` (Command level) already went through this exact same treatment earlier, via the LOP roadmap work, before this section was written.  
**Priority:** P2  
**Complexity:** M

### Target

Review every public DSL keyword against the rule:

> Would an SME plausibly understand this word without learning a software architecture pattern?

Likely candidates:

- `read_model` → `report` (keep alias)
- consider whether `aggregate` remains author-facing or becomes mostly structural documentation
- retain `command`, `role`, `goal`, `policy`, `event`, `query`, `lifecycle`, `given` if SMEs find them natural

Do not rename merely for novelty.

### Acceptance criteria

- compatibility aliases are era-safe.
- docs favor business terms.
- canonical IR remains normalized even when authoring aliases exist.

---

# 33. Semantic identity / provenance

**Status:** Done (2026-08-07), through the full self-hosted grammar — not
skipped the way `§7`'s `ir_version` was (that one is a computed constant;
`provenance` is author-facing DSL, so it belongs in the load-bearing
language description). `provenance from: { source:, source_id:,
source_version: }` on both `aggregate` and `command`, captured as a raw
Hash untouched — the exact shape sketched below, one level up from
`attribute ..., default: { ... }`'s own literal-Hash precedent, which it
reuses end to end: `AggregateBuilder#provenance`/`CommandBuilder
#provenance`, `IR::Aggregate#provenance`/`IR::Command#provenance` (in
`to_h`), new rows in `syntax.bluebook`, and — the part that makes it real
rather than decorative — `aggregate.bluebook`/`behavior.bluebook` (the
language's OWN grammar) gained a matching `attribute :provenance,
LiteralText`/`CommandText` on both the root record and the `Declare`
command, `Assembly::CONTRACTS`/`Shapes#provenance`/`Reconstruction#
aggregate` round-trip it, and all 9 golden IR fixtures were regenerated.
One real usage: Banking's `Account` aggregate now carries `provenance
from: { source: "HecksCanonical", source_id: "aggregate:account",
source_version: "1.0" }`, proving the path against the real corpus, not
just a synthetic fixture — `spec/round_trip_spec.rb` catches any future
drift here directly. Confirmed and left alone on purpose:
`readings.rb` needed no change (the judge's generic `field_value`
fallback already offers any field with no shape-differing exception);
`description` was confirmed NOT a usable precedent for Command
specifically (`CommandBuilder` has no `description` at all — the
asymmetry is real). Provenance never touches dispatch or identity, exactly
as the acceptance criteria below require.  
**Priority:** P1  
**Complexity:** M

### Current correlation

`IR::Command` comments explicitly state that identity is `(KIND, FQN)`, because names may collide across construct kinds.

UL projection and ontology upgrades complicate name-based identity because vocabulary intentionally changes.

### Target

Introduce provenance identifiers for adopted canonical concepts without replacing Hecks runtime identity.

For example:

```ruby
{
  kind: "command",
  fqn: "AcmePayments::Payment.ReverseCharge",
  provenance: {
    source: "Embryonaut::Payments",
    source_id: "command:payment.refund",
    source_version: "1.2"
  }
}
```

The organization FQN remains runtime identity. Provenance supports upgrades and semantic correspondence.

### Acceptance criteria

- organization can rename concept freely.
- upgrade tooling can still identify canonical ancestor.
- customer-created concepts simply have no canonical provenance.
- provenance does not affect runtime dispatch identity.

---

# 34. Architecture Decision Records

**Status:** Started — `docs/decisions/0001`, `0002`, `0007`, `0008`, `0009`, `0010` exist (restored 2026-08-07 alongside this document); `0011-rust-compiles-types-interprets-dispatch.md` (new, same day) records the real architecture §8 was actually built on and formally supersedes `0007`'s central claim (`0007`'s own Status line now points at it). `0003`–`0006` below were never written. `0009`/`0010` hold up as written — read `0007` as historical record of the original reasoning, same as §8's own superseded sections, not current architecture.  
**Priority:** P0  
**Complexity:** XS

### Target

Record irreversible or expensive design decisions in `docs/decisions/`.

Initial ADRs:

```text
0001-canonical-ir-is-runtime-independent.md
0002-one-command-one-role.md
0003-act-as-cross-domain-authority.md
0004-bluebooks-never-own-entropy.md
0005-ul-projection-preserves-ubiquitous-language.md
0006-ports-not-packages-drive-composition.md
0007-rust-generates-code-not-ruby-source.md
0008-reports-are-business-facing-read-models.md
```

### Template

```markdown
# Decision

## Context
...

## Decision
...

## Consequences
...

## Rejected alternatives
...
```

### Acceptance criteria

An agent implementing a feature can find the relevant decision without re-reading chat history.

---

# Recommended implementation order

> Reordered 2026-08-07 from a dependency/risk analysis of all 34 sections. The Rust/WASM/host-language sections were briefly pruned as obsolete after the Rust retirement, then restored at the user's request, then narrowed to a single runtime target: Rust (`§8`) plus its WASM compile output (`§9`) are the only runtime-projection sections in this roadmap — Ruby-hosts-Rust, Python, Go, and Java host bindings were removed rather than kept as separate speculative sections; OIDC and the other non-runtime projections were untouched by that decision and remain as before. `supporting` Bluebooks stays removed as already implemented. Each phase either has no unmet dependency on later work, or exists specifically to unblock the phase after it. Section numbers below (`§N`) refer to the numbered headings above.
>
> **Rust/WASM moved to Phase 2** (2026-08-07, second revision) per `docs/decisions/0010-ruby-is-the-reference-implementation.md`: it no longer waits for authority/ontology/canonical-domain work to finish. Ruby serves as both the implementer's guide and, through a continuously-run differential harness (§8's Milestone 0), the correctness oracle — so IR/behavior changes from later phases become fast-following, harness-verified extensions to the generator and kernel, not a reason to have waited. See §8 and 0010/0007 for the full reasoning; 0007's original "wait for Phases 2–4" entry criterion is superseded, kept in that ADR only as the reasoning this project moved past.
>
> Phases 1, 3, 4, 5 still read as one arc for the *authority/ontology* track specifically: harden the language (1), establish authority/identity semantics (3), establish ontology/provenance semantics (4), prove those semantics against real domains and a real corpus (5). Phase 2 (Rust/WASM) runs concurrently alongside that whole arc rather than waiting at its end, chasing each phase's IR/behavior additions as they land. Phase 6 onward project the same settled semantics outward into external ecosystems (auth protocols, history/analytics, persistence, standards, research).

## Phase 1 — Core hardening

`§1` duplicate-role guard · `§6` `report` alias · `§32` business-language DSL audit · `§7` IR version envelope · `§34` ADRs (start now, apply continuously)

All five are small, have zero dependencies on anything else in this plan, and directly reduce risk for every later phase: `§1` closes an authoring footgun before more commands get written against Governance/Identities; `§6`+`§32` fix vocabulary before it's baked into onboarding-facing tooling; `§7` gives every later projector (`§8`, `§10`, `§11`, `§15`, `§27`) a stable contract to target instead of an implicit one; `§34` should be adopted as a habit starting here, not treated as a single deliverable — every phase below changes an architectural invariant somewhere.

**Status note (2026-08-07 restore):** none of `§1`, `§6`, `§7`, `§32` were implemented — verified directly against the current codebase, not assumed. `§8` (Phase 2) proceeded anyway, out of the order this section recommends, and reached substantial completion without any of Phase 1 landing first; nothing about `§8`'s actual build depended on core hardening happening first. Worth noting as evidence either way: Phase 1 may matter less as a hard prerequisite than this ordering implied, or `§8`'s architecture change (interpret dispatch data, rather than the originally-planned pure codegen) is precisely what let it route around needing `§7`'s IR-version contract, `§1`'s role-cardinality guard, etc. Re-evaluate whether Phase 1 still belongs first before resuming this roadmap, rather than restarting it by default because it's numbered first.

## Phase 2 — Rust/WASM runtime

`§8` Rust projection, second attempt · `§9` WASM embedded Bluebook

**Status note (2026-08-07 restore):** `§8` is done, substantially, per its own "What actually got built" section — but not via this paragraph's plan. Read the note there before treating anything below as current.

Starts right after core hardening, not after authority/ontology/canonical-domain work — see the scope note above and `docs/decisions/0010-ruby-is-the-reference-implementation.md`. `§8`'s Milestone 0 (the differential harness against Ruby) is the actual gate from here on, not a phase boundary: build the harness first, then generate against Pizzas and Banking as they exist today. As Phase 3 (Governance, `act_as`), Phase 4 (UL projection/provenance), and Phase 5 (canonical domain expansion) land, each extends canonical IR and sometimes dispatch-pipeline behavior — `§8`'s "chase Ruby" section is the standing obligation that follows: extend the generator/kernel, re-run the harness, done when it's green, not accumulated as debt. `§9` is simply `§8`'s output compiled to a WASM target and depends directly on `§8`'s generator existing — there is exactly one runtime here, not a family of host bindings. Hold to `§8`'s own non-goals throughout: no second hand-written parser, no ported DSL builder, no full parity corpus, and no generic IR-interpreting kernel — Rust code is generated from canonical IR at build time, and no canonical IR is parsed or interpreted at runtime.

## Phase 3 — Authority & identity core

`§3` Governance Bluebook · `§4` Identities Bluebook · `§5` UUID adapter · `§2` `act_as` (wired to real `Governance.authorize_transition!`) · `§31` port fulfillment graph · `§33` semantic identity/provenance

**Status note (2026-08-07):** Every task in this phase is done — `§3`, `§5`, `§4`, `§2`, `§31`, and `§33` — see their own Status lines. `§2` landed with no dispatch-pipeline change at all (`CommandInterpreter`/`Dispatcher`/`CommandRules::Authorization` untouched) — the "Runtime execution" sketch below turned out to describe an application-level pattern composing `Governance.RoleTransition` + `Runtime::Caller.as`, not new pipeline plumbing, so the "first workload for Phase 2's chase-Ruby obligation" framing two paragraphs down did not end up applying to `§2` — nothing here changed Rust-relevant dispatch behavior.

This is the load-bearing phase for the authority/ontology arc: almost everything in Phase 4/5 assumes Governance and Identities exist. It's also the first real workload for Phase 2's "chase Ruby" obligation — `act_as` in particular adds dispatch-pipeline behavior, not just IR shape, so it's the first place the Rust kernel (not just the generator) needs a follow-up change. Order within the phase matters — `§5` (UUID adapter) should land before or alongside `§4`, since `Identity.Register` needs a UUID source for identity IDs with no natural key; `§2` can only be fully accepted (not just stubbed) once `§3` exists to make the authorization decision. `§31` and `§33` are cheap additions best made here, while the object model is still small: `§31` becomes meaningful the moment Governance/Identities exist as real fulfillments to graph, and `§33` (provenance on IR nodes) is far cheaper to add now than to retrofit once Onboarding (`§17`) and ontology upgrades (`§22`) depend on it.

At the end of this phase, command-level authorization is organizational rather than merely ambient-role matching.

## Phase 4 — Ontology adoption

`§30` Projector framework · `§15` UL Projection · `§16` UL adoption recipe · `§17` Onboarding Bluebook · `§18` role mapping review · `§19` existing-role discovery · `§21` semantic drift detection · `§22` canonical ontology upgrades · `§20` semantic mapping suggestions (AI, optional tail)

Build `§30` first — it's the general registration framework, and `§15` is its first real target, so building the framework in a vacuum before this phase would be guessing at an interface. `§15` → `§16` → `§17` → `§18` → `§19` follow the natural onboarding flow (project a canonical Bluebook into org vocabulary → keep the recipe → give onboarding a home → let SMEs review the mapping → let them discover existing roles to map onto). `§21` (drift detection) should land before `§22` (ontology upgrades), since upgrades are explicitly a three-way merge built on top of drift detection. `§20` is genuinely optional and lowest-value here — AI-ranked suggestions only matter once there's a real mapping backlog to rank, so it can trail or slip to a later pass without blocking anything.

At the end of this phase, a canonical Bluebook can be shipped and a customer can adopt it into its own language. UL projection/onboarding should not be allowed to destabilize runtime IR any more than necessary: vocabulary and provenance changes should land as a clean, bounded addition to the IR contract, not as ongoing churn — Phase 2's Rust generator extends to cover whatever this phase adds, verified by its harness, rather than treating onboarding as something Rust needs to wait on or stay in lockstep with.

## Phase 5 — Canonical domain expansion

`§14` People/Customers/Users decomposition · `§28` canonical corpus (ongoing)

`§14` depends on Identities/Governance (Phase 3) and is the first real test of the UL/onboarding machinery from Phase 4. `§28` isn't a single task — it's an ongoing practice of writing more canonical domains at the Phase 4 quality bar — but it can't produce anything credible until Governance, Identities, and People/Customers exist as its first real examples.

This phase still doubles as a stress test for the IR's expressiveness — writing real domains against Phase 3/4's semantics is how gaps in them surface — but per 0010, Rust (Phase 2) no longer waits for that proof before starting. Instead, whatever this phase finds and fixes about the IR flows into Phase 2 through the same "chase Ruby" mechanism as everything else, verified by the harness as it lands rather than gating Rust's start.

## Phase 6 — Auth projections

`§11` OIDC client projection · `§13` email OTP adapter · `§12` OIDC provider projection

Both `§11` and `§13` only need Identities (Phase 3) and can run in parallel — neither depends on Phase 2's Rust runtime. `§12` is ordered last and is by far the biggest lift (XL, full protocol surface) — it should wait until the client-side flow (`§11`) has validated the `(issuer, subject)` → Identity mapping in practice.

## Phase 7 — History & analytics

`§25` era-addressable query API · `§26` historical reports · `§27` data-engineering projections from reports

`§25` is mostly API surface over storage that already exists (`DeclarationSnapshot`, `era_check`, `era_tamper`) and unblocks `§26`'s historical/current interpretation modes. `§27` depends on both `§6` (the `report` keyword) and `§30` (the projector framework), both already in place by this point.

## Phase 8 — Persistence projection

`§10` SQL projection vs SQL runtime

Deliberately isolated as its own phase: Target A (DDL-as-artifact) is a moderate, low-risk win, but Target B (transactional command semantics as stored procedures) is research-grade and shouldn't gate anything else. Slot Target A wherever bandwidth allows once `§30` exists; treat Target B as optional.

## Phase 9 — Standards & compliance

`§23` ISO discovery and projection · `§24` standards conformance drift

Lower priority (P2) and largely independent of the rest of the roadmap, but `§24` explicitly depends on `§23` existing first (a mapping has to exist before its drift can be detected), and both benefit from `§21`'s drift-detection groundwork and `§33`'s provenance edges.

## Phase 10 — Research / long tail

`§29` GitHub/documentation pattern discovery

Lowest priority (P3) and least defined. Needs the canonical corpus (`§28`) to already be a going concern before a discovery pipeline for growing it is worth building.

---

# Definition of done for any new Hecks feature

A feature is not complete merely because the Ruby DSL accepts it.

An agent should check every applicable box:

- [ ] Business meaning is documented.
- [ ] Ruby authoring syntax is documented.
- [ ] Self-hosted language declaration is updated if grammar changed.
- [ ] IR represents the feature completely.
- [ ] `to_h` includes it.
- [ ] `Bluebook::Assembly` reconstructs it.
- [ ] golden/corpus coverage exists if wire shape changed.
- [ ] runtime executes or refuses it deterministically.
- [ ] replay does not perform new imperative work.
- [ ] era behavior is defined.
- [ ] translation/evolution behavior is defined.
- [ ] projection behavior is defined.
- [ ] adapter boundary is explicit for empirical work.
- [ ] refusal wording is deterministic and business-readable.
- [ ] existing Bluebooks still boot or a migration is supplied.
- [ ] docs/reference entry is updated.
- [ ] at least one realistic canonical Bluebook exercises the feature.
- [ ] fuzz/model-check coverage is added when the feature affects consequential state.
- [ ] ADR is added when the feature changes an architectural invariant.

---

# Central architectural summary

Hecks should remain a small language for executable organizational knowledge. The canonical IR is the durable semantic representation. Ruby is an excellent authoring/runtime environment but not a mandatory deployment dependency — a second hand-written interpreter maintained through differential parity is a cost this project has already paid once and retired (see `docs/rust-experiment.md`), so any non-Ruby runtime must consume canonical IR through a thin projection with a small handwritten kernel, not reimplement semantics from scratch. Ports define required capabilities; Bluebooks or adapters fulfill them. Imperative facts such as UUIDs, time, authentication results, and external API responses enter through adapters and become durable history. Commands carry a single responsibility role; Governance maps real organizational authority onto those roles and controls `act_as` transitions. Reports expose the analytical face of the same organizational model. Canonical Bluebooks can be adopted through UL Projection so organizations gain reusable ontology without giving up their own language. Eras preserve both facts and the interpreter that gave those facts meaning. Projections then carry the same organizational knowledge into Rust, WASM, OIDC, SQL, documentation, standards, and future ecosystems without forcing the core language to grow.


---
# Appendix — Future Direction

The roadmap should evolve alongside the codebase.

When implementing any feature:

- Update this document.
- Add or update Architecture Decision Records (ADRs).
- Add acceptance tests.
- Preserve replay determinism.
- Prefer extending IR, projections, adapters, or supporting Bluebooks over expanding the core DSL.
- Ensure new concepts can be projected consistently across target projections.

This document is intended to become the long-term architectural memory of HecksAgain.
