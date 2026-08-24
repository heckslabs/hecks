# Unbuilt

Every planned, proposed, and not-yet-built feature collected across hecks's implementation plan, PRDs, work-slice plans, decision records, guides, and bug audits — with the shipped and the live left out.

**Sources:** 20+ docs across `docs/`, `docs/prds/`, `docs/decisions/`, `docs/guides/`, `docs/audits/` (as of the 2026-08-18 `docs/` split into `docs/implemented/` vs. active work — see that split for what's now shipped).
**Compiled:** 2026-08-18

---

## Top priorities

The clearest signal in the whole tree is the survey's own closing pick — an explicit "if we build three." Everything else here ranks by how concretely it's scoped and how much else depends on it.

1. **A universal dispatch MCP door** — `dispatch / query / state / catalog / describe / validate`, every call carrying a required `summary`. `bin/run` and the `Facade` already exist to project it from.
2. **`follow` + `SourceTag`** — persist the dispatch stream already emitted (event log plus caller kind: process-manager / operator / hook / sidequest-agent / cascade / daemon), add a JSONL tail and a `bin/follow`.
3. **Drivers** — `driving on interval | cron | clock` in the hecksagon DSL, projected to a Makefile/Procfile target. The sibling `hecks` project is explicitly blocked on hecks for exactly this.

### Highest-signal items from the rest of the corpus

- **Reaction-depth race (PRD 01)** — `@reaction_depth` in `dispatcher.rb` is an unguarded thread-shared ivar: a live, already-diagnosed, unfixed concurrency bug. Small and ready now.
- **Fuzzer against real adapters (PRD 02)** — the whole property-testing arc has only ever run against the Memory adapter, never Sqlite or Postgres. Largest PRD in scope; unblocks PRDs 03 and 08.
- **Audit Tier 1, findings H3–H5** — open data-loss bugs in era-migration and rekey machinery. The most severe unresolved findings anywhere in the docs.
- **Drivers / Gates / mailboxes / OutboundEvent / derivability gauge** — a coherent "operational surface around the bus" that `hecks` has built and hecks lacks entirely (survey items 3, 5, 6, 7, 8).
- **ADR 0025's DSL cleanup** — a fully sequenced 15-step plan; the single largest concretely-scoped item among the decision records.
- **Query-DSL aggregation** — `count / sum / avg / min / max` plus `group_by`. Flagged as the sharpest, most requested gap in the query language.

---

## Wishlist survey

`docs/hecks-survey-what-we-wish-we-had.md` — a 2026-08-17 read of the sibling `hecks` project asking one question: what does it have — especially "Storehouse" — that hecks wishes it had.

### Storehouse, ranked

1. **Universal MCP door, three zoom levels.** Ten tools (`dispatch, query, state, catalog, describe_aggregate, list_aggregates, validate, macrophage_check, behaviors, conceive_behaviors`), no per-command wrappers. hecks has only a 3-tool query-IR MCP.
2. **`follow`.** A live, cross-process tail of every dispatch, feeding both an MCP resource and a queryable `StorehouseEntry` domain. hecks has only after-the-fact `bin/history`.
3. **Drivers.** Inbound clocks (`interval | cron | clock`) declared in the hecksagon, projected to a Procfile — out-of-process by construction, so a dead clock stalls only its own task. hecks's DSL has no inbound-scheduling concept at all.
4. **`SourceTag`.** A closed enum of dispatcher provenance. Cheap to add.
5. **Gates.** Inbound middleware as bluebook records — `before/after` phase, a check that can be any bluebook query run read-only as a veto, ordered, hydrated at boot. hecks's authz today is one hardcoded file with no query-as-veto, ordering, or after-phase observers.
6. **Actor mailboxes.** `poisoned` as a first-class status, plus `--json` and a `--fixture` deterministic demo mode for inspection tooling.
7. **A standing derivability gauge.** A periodic driver that folds the full event log and records `derivable | drifted`, separating transient from persistent drift and tracking missing rows on their own. hecks has no continuous proof that the fold of its log equals its state.
8. **`OutboundEvent`.** A durable outbox (`pending → claimed → delivered | failed`) for effect-port edges with idempotent delivery ids and a shared adapter-host protocol. hecks's effect ports drop on restart today.
9. **Honest-refusal tools.** Structured `{ok:false, supported:false, error:"…"}` instead of a crash, an ENOENT, or a silent no-op.
10. **A two-tier bus design.** A local, free, eventually-consistent bus alongside a durable, governed, paid one, chosen per bluebook with domain-level default and aggregate-level override. Would collapse repeated `persisted_by` lines to one.

### Beyond Storehouse — worth stealing

- A `Session.RebuildContext` plus a Stop-hook handoff gate that regenerates working context from durable state.
- Inbox-card conventions: a `value:` field carrying the whole finding, a `closed_note:` recording what actually fixed it, mandatory "Where to look" and "Verification once fixed."
- An antibody + lines-of-code ratchet with signed, retirement-conditioned exemptions and longest-prefix classification.
- `ProducedField` — the typed *output* half of an adapter contract; hecks's `.port` files type inputs only.
- Family-owned `.world` schema validation that rejects unknown or missing keys and infers a field's source (`direct | env | secret`) from its declaration form.
- Generated `.behaviors` tests from the IR, with a closed precondition taxonomy that fails loudly on any unhandled `given`. The authoring DSL exists on the hecks side; there's no interpreter under it yet.
- A morphology promotion loop — a static fast path plus a dynamic learning path, promoting a candidate word at three rejections.
- A tool-cache built from transcript JSONL, catalogued at session start.
- Decentralized, opt-in registries via dropped descriptor files.
- A sidequest stop-rule: one verification pass, maximum; inconclusive is a stop, not a loop.

---

## Implementation plan

`docs/HECKS_IMPLEMENTATION_PLAN.md` — the largest single source by far, 2,511 lines. Phase 1 hardening is still incomplete; phases 4 through 10 (ontology adoption, canonical-domain expansion, auth projections, history & analytics, persistence projection, standards & compliance, research tail) haven't started.

### Foundational architecture

- Formalize the twelve-stage deterministic execution pipeline with per-stage docs covering replay, determinism, and failure semantics.
- Keep three independent IRs — Authoring, Execution, Evidence — distinct.
- Expose a runtime **Capability Graph** (Governance, Identity, UUID, Clock, Persistence, Email, Payments…) for deployment analysis, onboarding, and AI reasoning.
- Expose a navigable **Semantic Graph** (Command→Role, Command→Event, Event→Policy…) so tooling stops parsing Ruby directly.
- A **Constraint Engine** that models rules as constraints and can explain blocked work by walking the dependency chain.
- Explainability — a rendered explanation tree for every runtime decision, adjustable by audience.
- Extend `hecks verify` past reachability/consistency to dead-command/event/policy detection, cycle detection, impossible transitions, conflicting invariants, duplicate rules, unreachable states, unused roles and value objects.
- Diagram generation straight from canonical IR, no hand-maintained diagrams.
- An AI-assistant layer for ontology discovery, corpus evolution, role mapping, upgrade suggestions, and drift explanation.
- Capture every architectural invariant as an ADR.

### By section — all unbuilt or partial unless noted

- **§1 role uniqueness** — enforce one-command-one-role at the builder level; a duplicate `role` currently silently overwrites instead of raising.
- **§2 `act_as`** — facade sugar for cross-command role transitions.
- **§3 governance** — wire `act_as` to a real `Governance.authorize_transition!`; add a port/query surface for other domains.
- **§4 identities** — OIDC verification (feeds §11); retrofit Governance's `actor_id` to reference Identity.
- **§5 UUID adapter** — facade-level auto-enrichment of identity args, retrofitted across the existing corpus.
- **§6 `report`** — a permanent SME-facing alias for `read_model`, with builder dispatch, vocabulary docs, and golden round-trip tests.
- **§8 Rust projection** — WASM target; era-minting and shape-drift detection in Rust; SQL translation from Rust; era-partitioned read-back; a Rust `LineageManager` equivalent; refusal-wording parity; wiring `bin/rust_conformance` into an automated gate.
- **§9 WASM embedded bluebook** — era selection, a browser JS API (`Hecks.load/dispatch/report`), a host-adapter import boundary, and state externalization/hot-reload.
- **§10 SQL projection** — generating Postgres/SQLite DDL from IR, and compiling command semantics into stored procs/triggers/views (research spike).
- **§11–§12 OIDC** — a real client-facing flow (redirect, code exchange, JWKS verification) and, further out, a full OIDC provider (endpoints, key rotation, conformance testing).
- **§13 email OTP adapter** — `RequestLoginCode`, code generation/send adapters, rate limiting.
- **§14** — split People/Customers/Users/Governance into a proposed corpus.
- **§15–§16 UL projection** — a `Hecks.ul_projection` DSL, a `ULProjector`, and replayable mapping recipes for future canonical releases.
- **§17–§20 onboarding** — an entire Onboarding domain (Adoption, MappingDecision, Conflict, Recommendation), a role-mapping review UI, existing-role discovery, and (lowest priority) AI-assisted mapping suggestions.
- **§21–§22 drift** — semantic drift detection across Canonical↔Org, ISO↔Bluebook, Bluebook↔artifact, and Era N↔N+1; a three-way semantic-merge upgrade workflow.
- **§23–§24 standards** — ISO traceability mapping and conformance-drift detection built on top of it.
- **§25–§27 history** — querying and reporting by era, plus data-engineering projections from reports.
- **§28–§29 canonical corpus** — reusable canonical bluebooks (Money, Identity, Governance, People, Payments, Inventory, Scheduling, Audit, Quality/CAPA…) and a pattern-discovery pipeline to help author them.
- **§30 projectors** — retrofit the real `:rust` projector into the `Projector` framework; build the unbuilt `:ul` and `:openid` projectors.
- **§31 port fulfillment UI** — the data exists; the UI doesn't.
- **§34 missing ADRs** — cross-domain authority, bluebooks-never-own-entropy, UL-preserves-ubiquitous-language, ports-not-packages.

---

## Work-slice plans

Five smaller, more mechanical planning docs — each scoped to a concrete engineering slice rather than a product feature.

### DSL work slices (`docs/dsl-work-slices.md`)

- **S12 — `projects` and the boundary rule** (Wave 3): delete `References#dereference`, migrate 49 givens, build an adapter-agnostic rebuild path and a new `ProjectionAbsent` refusal from scratch.
- **S13 — coverage standard** (Wave 3, depends on everything): corpus-use or a written exemption for 11 not-yet-adopted vocabulary words.
- Open items still needing a home: the `domain_port` vs. `port` naming split; ambiguity in `Domain::Aggregate.X.Y` between an entity command and a port operation; an undocumented `parent` construct; the unresolved `report` vs. `read_model` disagreement between ADR 0008 and 0025; a flaky adapter-agreement gate that has blocked pushes roughly one push in six.

### Fuzzer property expansion (`docs/fuzzer-property-expansion-plan.md`)

- Fix and prove an entity-identity collision in `MutationApplier#entity_element`.
- New property: stored records satisfy their declared invariants (catches invariant-violating writes that are never refused).
- New property: `group_by` results match a from-scratch recompute.
- Fix: the query interpreter never applies `offset` — then add a paging property to prove it once fixed.
- New property: lifecycle guard and given violations are always refused (needs a new replay snapshot hook).
- New property: scope authorization actually refuses (currently unreachable — the generator never supplies `tenant:` args).
- New property: dispatch-binding fidelity, backed by an additive saga dispatch log.
- New property (the largest item): mutations match an independent recompute — needs a real bootable entity-mutation domain and per-operation recompute functions.
- Secondary fixes: an unenforced entity-identity/remove interaction; a lifecycle guard bypassing shared refusal wording; `clamp` missing the zero-fallback that `multiply`/`increment` already have.
- Explicitly deferred, no properties yet: `cursor`, `consistency`, `freshness`, `use_index`.

### Postgres-era adapter split (`docs/postgres-era-adapter-split-plan.md`)

- An **`OracleEra` adapter** — deferred for now but flagged as a strong future candidate (clears every bar: incremental materialized views, online partitioning, transaction-scoped advisory locks).
- Re-check CockroachDB advisory-lock support before treating its exclusion as permanent.
- Two open gaps in the `all()`/`save()` migration path: saga/process-manager state needs its own explicit read-and-reinsert step, and the `mirrors` field on `Entry` hasn't been fully traced.

> Note: the rest of this plan is now marked done and verified; it moved to `docs/implemented/` in the 2026-08-18 docs split, with the three items above being the only genuinely open threads.

### Rust experiment & handwritten refactor

- `rust-handwritten-refactor-slices.md` — Wave 0 creation slices (new module files: `kernel.rs`, `parse/gates.rs`, `lex.rs`, `emit.rs`, `ruby_value.rs`, `auth.rs`, `web.rs`, `journal.rs`); Wave 1 integration slices shrinking the old monoliths and rewiring 35+ call sites (`I-PARSER, I-HOST, I-CODEGEN, I-BUILD`). Named for possible later slices: extracting `AwsLambdaInvoker`; deduping triplicated `puts_str`/`puts_blank` helpers; a `pub` → `pub(crate)` visibility-hygiene pass.

---

## PRDs

`docs/prds/` — eight proposals, in the priority order the README itself gives.

- **01 · Reaction-depth race.** Guard `@reaction_depth` with a mutex, mirroring the existing `@saga_mutex` fix; add a concurrent-dispatch stress test.
- **02 · Fuzzer against real adapters.** Give `IsolatedBoot` a real-adapter mode — Sqlite required, Postgres behind an `io: true` flag — so the 15-property battery runs against real persistence, not only Memory.
- **03 · Mutation application agreement.** A differential gate across adapters for `append/remove/multiply/clamp/increment/decrement/set`, mirroring the query-agreement spec that already found four real bugs.
- **04 · Rust conformance fuzzing.** Bridge randomized sequences into the existing Ruby-vs-Rust byte-for-byte conformance spec; run any divergence through the existing shrinker.
- **05 · Numeric boundary coverage.** Widen integer and float edge cases (Int64/Bignum, NaN/Infinity/-0.0) and trace each through coercion, `multiply`, and `clamp` for silent corruption.
- **06 · Parser adversarial fuzzing.** A `cargo-fuzz` target seeded from the real corpus, checking only "never panics, always a clean error."
- **07 · Ruby mutation testing.** Evaluate the `mutant` gem, scoped narrowly to `command_interpreter.rb`, `mutation_applier.rb`, and `argument_gate.rb`; triage every surviving mutant. Deliberately scheduled late.
- **08 · Coverage-guided fuzzing.** Instrument `bin/fuzz`'s generation loop with real coverage feedback via Ruby's `coverage` stdlib. Deliberately last — most valuable once 02 and 04 have landed.

---

## Query DSL & policies

### Query DSL (`docs/query-dsl.md`) — proposed additions, none implemented

- **Aggregation** — `count / sum / avg / min / max` plus `group_by`. The sharpest gap: nothing computes anything today.
- **`having`** — filtering on a computed value, paired with aggregation.
- **`distinct`** — a common primitive with no equivalent today.
- **Explicit `include` optionality control** — no lever today for "drop the row if the include is absent" vs. "keep it with an empty collection"; inner-vs-left-join behavior on a zero-match has never been traced.
- Compiling a hop into a real SQL `JOIN` instead of two round trips — worth doing only if measured to matter.
- Era/time-aware reads ("as of") — the most speculative item; may already be solved elsewhere under a different name.

### Event-storming policies (`docs/event-storming-policies.md`)

- No "external system" concept — a policy can't declare an effect reaching past the runtime boundary (email, webhook, third-party API) as a checkable fact, the way `across` does for cross-domain reach.

---

## Decision records

Only the ADRs with genuine unbuilt content, per their own status marker — pure rationale-only or fully-shipped records moved to `docs/implemented/decisions/` in the 2026-08-18 docs split and are left out here.

- **0010 — Ruby as reference implementation.** Accepted, not implemented: a differential test harness that dispatches the same command sequences into Ruby and a second runtime, diffing outcomes, refusal wording, events, and state — the real gate for ever shipping a second runtime.
- **0022 — self-host the expression grammar.** Proposed, not implemented: describe the expression-node grammar in the bluebook meta-language so Ruby's evaluator and Rust's `kernel/expr.rs` can be checked against one shared description. A prerequisite corpus audit hasn't happened, and whether it's worth building at all is still open.
- **0023 — Rust parses and compiles directly.** The parsing half is implemented and verified; the codegen half — porting `rust/project/*.rb` so `cargo build` needs no Ruby at all — is explicit, separate, unstarted follow-on work.
- **0025 — one idea, one way.** Accepted, not implemented — a fully sequenced fifteen-step plan: collapse duplicate `identified_by` spellings; retire `_id` minting in favor of `/` traversal; delete `has_many`/`has_one`/`belongs_to`; require a single bare-constant attribute type; delete `consistency`/`freshness`/`use_index`; revert `report` back to `read_model`; rename `then_set` to `sets` (143 corpus uses already match); make `role` real RBAC or refuse it; make events and command references first-class; unify saga and lifecycle vocabulary; add an aggregate-level `invariant`; make lifecycle state a real command guard; add a `projects` construct with a `ProjectionAbsent` refusal; require `EraGuard` translation for newly-optional attributes.
- **0026 — the language uses everything it declares.** Accepted, not implemented: a self-use gate that will fail on day one against the language's own chapters; demoting `limit`/`offset`/`cursor`/`nulls` into a `Paging` sub-language; turning the language's own `Status` field into a real `lifecycle`; promoting `Member`/`Dispatch`/`Handler` to real entities.

---

## Guides & reference

`docs/command-form-and-query-form-bluebook.md` (status: prototype) — largest cluster of still-open guide-level work: graduate it from an ordinary Ruby DSL into real syntax validated through `Hecks.*`; give `expose` per-command and per-query override instead of whole-chapter only; add field-level refusal attribution to the sticky re-render (today it's whole-banner only); wire up reports/read models (`report_form.bluebook` is a reserved name only so far); replace the one-JSON-object-per-line fallback for a multi-field `list_of` with a real repeatable add/remove fieldset; and eventually add styling, live sockets, and a real deploy target — all currently deferred to a wider web-framework idea, with `bin/present` staying dev-only until then.

`docs/rails-integration.md` — status: design only, nothing built. Explicitly open, not designed here: the read side beyond one load-bearing `show` route; authorization enforcement; per-attribute labels/help text; file uploads; real-time updates via ActionCable; which driven adapters should be Rails-native vs. agnostic.

`docs/resolution-rules/cross-entity-given.md` — the only one of the four resolution-rules docs not yet mirrored into the Rust parser (the other three moved to `docs/implemented/resolution-rules/` in the docs split).

---

## Bug audits

`docs/audits/2026-08-10-main-bug-audit.md` and `docs/audits/2026-08-11-bug-triage.md` — 75 findings total. Only H1 and H2 are marked fixed — everything below was still open as of 2026-08-11.

### Tier 1 — data loss & migration integrity

- **H3** — deleting an era-migrated record resurrects it: the ancestor era's row survives a `DISTINCT ON`.
- **H4** — rekey SQL is invisible to the human-approval digest; two different rekey statements can share one digest.
- **H5** — a dotted-member `compute` exempts the whole attribute from the cross-execution equivalence gate that exists specifically to catch it.

### Tier 2–3 — systemic roots & security

- **S1** — `render_value` collapses typed query values to `.to_s`, erasing type tags on the wire.
- **S2** — `h[k.to_sym] || h[k]` turns a stored `false` into `nil`.
- **S3** — unconstrained aggregate identity values flow unescaped into URLs and HTML.
- **H10** — stored XSS via a record id in the Rust web layer.
- **H11** — session HMAC fails open on an empty `SESSION_SECRET`.
- **L12** — record ids are HTML-escaped but never URL-encoded.
- **L20** — `rename-schema` interpolates unsanitized SQL.

### Tier 4 — wrong answers & broken routes

- **H6** — `limit` is applied before `offset` in the in-memory query port.
- **H7** — the reference/entity query engine ignores `offset` and bypasses `FieldPath.dig` for dotted fields.
- **H8** — `seal_defaults` doesn't cover `one_of` closed sets: boots clean, then refuses every create.
- **H9** — the meta-validator cache key omits read-model filters, so a stale filter survives an edit.
- **H12** — record ids containing a `.` are unroutable.
- Plus 20 medium-severity findings (M1–M20): query null/type semantics divergence, inexpressible negated membership, raw `TypeError`s crossing the refusal boundary, IR round-trip losses, DSL sealing gaps.

### Tier 5–7 — ops, harness, and low severity

- **H13** — `make deploy` always exits non-zero for Shared-mode domains.
- **H14** — generated translation-audit targets silently hit the local DB instead of the intended prod tunnel.
- Test-harness blind spots: three half-unfuzzable framework aggregates; a vacuously-passing saga property; a fuzzer query oracle that masks refusal-shaped divergence; `shrink_arguments` never accumulating drops; an absorbing-state contradiction in `RoleTransition`.
- Rust-parity divergence across the full corpus: payload nil-vs-omitted mismatch, a refusal-count divergence of 94 vs. 131, dispatch-order inversion, inconsistent empty-string identity handling, and `cargo build --features banking` failing outright.
- 24 low-severity findings: `catch_up!` strict-mode gaps, single-column checks on multi-column `one_of` sets, missing 404/422 handling, SQLite/D1 text-null vs. Postgres NULL divergence, f64→i64 saturation, and assorted Rust web-layer panics.

---

## Also reviewed, nothing to add

`docs/documentation-plan.md` (describes already-completed work, landed 2026-08-04 — moved to `docs/implemented/`) and the ADRs now under `docs/implemented/decisions/` — rationale-only or fully shipped, no unbuilt content remaining.

---

*Compiled from `~/Projects/hecks/docs/` — worktree copies and build output excluded. Re-check open items against current state before acting; several of these plans are weeks old and `docs/` was split into `docs/implemented/` vs. active work on 2026-08-18, so file paths above may have moved.*
