# PLAN — The Payload Gate : an anticorruption layer at the dispatch threshold

**Decided with Chris, 2026-07-18 (workshop-demo session).**
**The ruling : the domain can always assume its payloads are valid. All calls, all doors.**

## Why (the evidence, from tonight's live session)

Three corruption classes crossed the threshold today, all `ok:true` :
1. **Empty command** — `AddTool` with zero attrs minted a phantom Tool record (required attributes unenforced ; IR carries `required: bool`, nothing reads it at dispatch).
2. **Invariant-violating value** — `daily_fee: "-5"` accepted despite `invariant "must be non-negative" { cents >= 0 }` on the Fee VO. Declared ≠ enforced : `storehouse validate` argues about the bluebook ; nothing argues about the payload.
3. **Silently-dropped keys** — fixed at the HTTP door only (stray body key → 400 with did-you-mean). The other doors still swallow.

## The architecture (as talked out — keep this framing)

**Parse, don't validate.** The gate does not check-and-forward raw attrs — it CONSTRUCTS typed values from them and refuses when construction fails. Inside the boundary, an invalid Fee is unrepresentable ; the domain contains zero defensive code as a *consequence*, not a convention.

**Anticorruption layer, aimed outward.** Evans's ACL protects one context's model from another's ; this one protects the domain from the ungoverned world (curl bodies, form posts, MCP args, adapter re-entries). Everything outside the hexagon is a foreign context. The gate is the customs office at the port.

**Nothing to declare — the bluebook already says everything.** The gate is a kernel interpreter over existing IR :
- `attribute :daily_fee, Fee` → which VO to construct
- VO shape (`cents: Integer`) → parse target + type coercion rules
- VO `invariant` blocks → predicates to run at construction (reuse the same expression interpreter the `given` blocks use — runtime/interpreter.rs)
- `required` (attr.default.is_none()) → presence rules
- reference declarations → the ref id must be present (and, later, resolvable)
- (follow-on) `one_of("USD","EUR")` enumeration → vocabulary check — NOT in this arc ; needs its own grammar card ; Pizzas carries the exemplar when it lands

**The two-kingdom split :**
| | reads | needs state? | runs |
|---|---|---|---|
| Invariants (VOs) | payload alone | no | at the gate (ACL) |
| Givens (commands) | hydrated aggregate | yes | in the domain, unchanged |

Payload validity is value-intrinsic ; business preconditions are state-dependent. The gate never touches a repository.

## Where it lives — ONE chokepoint, not per-door

NOT a per-door filter. The gate sits at the single shared dispatch entry (`rt.dispatch` / the embed one-shot entry from 1d76539bf — the same entry the CLI, HTTP serve, serve-stdio, MCP door, and magnus native bindings all funnel through). One gate, every door inherits it — including doors not yet built. Cascade-internal dispatches (policy re-entries, adapter verdict commands like Authorize/Decline) pass through the SAME gate — a cascade carrying an invalid payload is still corruption ; System-role commands get no exemption.

## Refusal contract

Refuse BEFORE any state touch : no event, no record, no cascade. Error shape is the existing humanized contract the served UI already renders : `{ message, suggestion, field }` — e.g. `{ message: "Daily Fee must be non-negative", suggestion: "you sent -5", field: "daily_fee" }`. Field-targeted so the form rings the exact input. CLI prints it ; MCP returns it structured.

## Forward projection (later phase, note only)

Because the rules are IR, the same invariants can project into the form as pre-flight JS courtesy checks (instant red ring) while the gate remains the law. No drift possible — neither side is hand-written. Do NOT hand-code form validation in the meantime.

## Implementation sketch (fresh-head, gated worktree)

1. `runtime/command_dispatch.rs` (or a new `runtime/payload_gate.rs` — 200-line rule) : before id resolution / mutations —
   a. required check : every command attribute with no default must be present and non-empty ; every declared reference resolved to an id.
   b. VO construction : coerce each attr into its declared VO shape (wrapper VOs unwrap as the form renderer does).
   c. invariant evaluation : run each VO invariant via the given-block interpreter with the constructed fields bound ; first failure → refusal.
2. Wire the refusal through dispatch’s error path (CLI, HTTP routes.rs dispatch, serve-stdio, MCP dispatcher all already surface dispatch errors).
3. Tests : new `payload_gate_test.rs` — empty-create refused ; negative-invariant refused ; valid payload unchanged ; cascade re-entry gated ; singleton/default-injection paths (ROOT-3, i111-K) still work — the existing identity-injection runs BEFORE the required check so declared defaults satisfy presence.
4. Gates : full cargo workspace tests + behaviors + parity. Watch the Ruby side : behaviors state_resolver mirrors dispatch semantics — if behaviors suites dispatch invalid payloads as fixtures, they now refuse (that’s the point — fix the fixtures, never soften the gate).
5. Demo re-probe : `daily_fee=-5` → refused with field-targeted error ; empty AddTool → refused ; ToolShed store stays clean.

## LANDED — 2026-07-18, same session, all gates green
- **VO invariants bite** : ValueObject IR carries invariants ; Rust parser captures the canon `invariant "..." do <pred> end` form (was silently dropped — Ruby collected them since day one) ; `runtime/payload_gate.rs` judges incoming attrs pre-hydration via the given-block evaluator ; `RuntimeError::PayloadInvariantViolation {name, expression, field, value}`.
- **Required attributes** : explicit `required: true` opt-in (both parsers already carried the flag ; Ruby structure/attribute.rb stated the contract). Refuses absent/Null/empty. Form asterisk now renders from `attr.required` — words match state. Corpus free-omission style untouched.
- **Reference counter-mint closed** : a SELF-ref on an identity-LESS aggregate absent from the payload refuses instead of counter-minting (ReturnTool no longer invents a Loan born returned). Identity-bearing self-refs defer to the identity machinery (natural key / ROOT-3 defaults / singleton reuse) ; cascade-hinted dispatches trusted.
- **Parity gaps closed** : aggregate `identified_by`, attribute `required`, VO invariant NAMES (Ruby holds predicates as Procs — names are the shared contract) now in BOTH canonical dumpers ; fixture `24_payload_gate.bluebook` proves byte-equality ; parity 385/387 with only the pre-existing known-drift.
- Tests : `payload_gate_test.rs` 11/11 ; full workspace sweep clean ; zero warnings.

## Standing follow-ons this arc unblocks
- **Foreign-reference presence** — needs the corpus survey first : existing flows legitimately omit foreign refs relying on implicit-singleton parents (restructure's Placement.Add). Ruby's `validate: :exists` default states the intent ; enforcement waits on the survey.
- **Retro-audit sweep** — Driver-shaped (Kitchen/ExpireStale pattern) : walk records against CURRENT invariants when the law changes ; emits InvariantViolationFound. Gate guards the future ; sweep names the past.
- **Multi-attribute VO construction** — phase-1 gate covers wrapper-shaped VOs ; nested payload construction arrives with one_of/type work.
- `one_of` enumeration grammar (currency vocabulary ; form dropdown projection) — GRAMMAR-one-of-closed-value-sets.md.
- Composite `identified_by :name, :category` (IdentityString ids) — own card, exploration notes in session 2026-07-18.
- Query-door governance parity (gate reads on the same IR) — evaluate after dispatch gate lands.
- JSON Schema projection — PLAN-json-schema-projection.md (now with `required` + invariant→minimum mappable from live IR).
