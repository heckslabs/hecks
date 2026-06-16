# Design — Event Sourcing + Actor + Lineage (one kernel arc)

**Status:** DESIGN ONLY. Not started. Proposed as the next arc, fresh-headed
(kernel-floor struct change ; do not begin at high context).
**Date:** 2026-06-16. **Origin:** Chris, mid-session, named three things that
are facets of ONE arc :
  1. "record who called commands — the role — on the event"  (the **actor** dimension)
  2. "it might be time for event sourcing — I should see what's changing, what
     was read, what was written"  (**persist** the stream + make it inspectable)
  3. "for governance we need lineage"  (**causation + correlation** — who triggered what)

These unify : **make the event the unit of an attributable, persisted,
causally-linked audit log.**

---

## The kernel reality today (verified 2026-06-16)

`rust/src/runtime/event_bus.rs` — the `Event` struct is deliberately minimal :

```rust
pub struct Event {
    pub name: String,
    pub aggregate_type: String,
    pub aggregate_id: String,
    pub data: HashMap<String, Value>,
}
```

- **No actor / role.** Nothing records who dispatched the command.
- **No timestamp, no ids.** No event_id / causation_id / correlation_id on the struct.
- **Not persisted as a stream.** `EventBus.history: Vec<Event>` is in-memory only ;
  it dies with the process. `EventTrace` (`dispatch_detail.rs`, kind/verb/ok) is
  ephemeral, thread-local, built only for the wire reply.
- Commands DO carry a declared `role` in the bluebook (parsed at
  `parse_blocks.rs:222`), but it never reaches the emitted event.

## The reframe that makes this tractable

This is **not** build-from-scratch. Every door call is ALREADY a bus event —
that is the governance premise just proven by the GovernedDoor lockdown. So :

- **Emission already exists.** The gap is **persistence + envelope enrichment**,
  not emission.
- **"See what was read / written" largely falls out for free** — `FileTool.Read`,
  `FileTool.Edit`, `ShellTool.Bash` all dispatch through the door now, so once the
  door stream is persisted, reads and writes are already in it. No new capture
  path ; persist the stream we emit.

---

## DECIDE-API-FIRST — settle these with Chris BEFORE touching the struct

### Q1 (the hard one) — declared role vs actual actor
Bluebook commands declare ONE *authorized* `role` (static : `RecordBlock` → "Hook",
`Register` → "Miette"). Governance lineage wants the *actual* caller. For
`NativeToolBlocked` the declared role is "Hook" but the real actor is
Miette-or-agent-X who attempted the native tool — and the PreToolUse hook cannot
easily see which. **This is the crux of "for governance we need lineage."** Do we
stamp (a) the declared role, (b) a runtime-supplied actor identity threaded
through dispatch, or (c) both (declared role for authz, actor for lineage)? Do
NOT let this resolve silently to "use the declared role."

### Q2 — reconcile with the existing event-id
`event_bus.rs` already references **idempotency-by-event-id** in the actor/mailbox
path (the mailbox seen-set). Before minting `event_id` / `causation_id` /
`correlation_id`, verify how that existing id works so we don't create a second,
colliding id concept.

### Q3 — where does the persisted stream live, and what's its bluebook?
Bluebook-first : the event log is a domain concept, not a raw .heki dump.
Model it — an `EventLog` aggregate? an envelope value-object on every event?
The enriched envelope (actor + ids + timestamp + causation/correlation) must be
conceived as a bluebook before the Rust struct changes, so the struct is a
projection of the domain, not the reverse.

### Q4 — scope of "see what's changing"
State deltas (before/after) or just the event + its data? Full event sourcing
implies state is REBUILDABLE from the stream (snapshots + replay). Is that the
target, or is the near-term goal an attributable audit *view* (Chris reading
what changed) without full replay-as-source-of-truth? These are different sizes.

---

## Ripple (why this is fresh-head work, not a patch)

The `Event` struct change touches every construction site, the **Ruby/Rust
parity tests**, and the **wire/persistence format**. That is the byte-precise,
parity-gated work that prior restart notes explicitly fence off from a
high-context session. The only "quick" version — stuffing role into the `data`
HashMap — is the bluebook-first violation this whole design exists to avoid.
**No down-payment. Conceive the envelope bluebook first, decide Q1–Q4, then the
Rust struct follows as a projection.**

## TWO lineages — domain vs governance (Chris, 2026-06-16, load-bearing)

They are not separate ledgers. Governance lineage is the **actor-attributed,
integrity-guaranteed PROJECTION of the same causal chain.** The
causation/correlation backbone is the substrate ; governance is what you get when
every hop additionally carries actor + authority + integrity.

- **Domain / event-sourcing lineage** answers *what caused what* : command → event
  → reaction-command → event, stitched with **causation_id** (the direct parent)
  and **correlation_id** (the whole originating chain). Purpose : replay,
  debugging, consistency — the causal graph of state changes. Content with
  "event B was caused by command A."
- **AI-governance lineage** answers *who acted, under what authority, and is it
  trustworthy* : which **actor** (me / the Hook / agent X / the underlying model)
  issued each command, on whose **delegation**, plus a tamper-evident guarantee
  the record wasn't altered after the fact. Purpose : accountability,
  non-repudiation. Demands "actor M, role Miette, caused A, runtime caused B from
  it — and here is proof nobody edited that afterward."

The three governance additions on top of the causal spine :
1. **Actor + role at each link** — the "record who called the command" ask. THE
   HINGE, not a nice-to-have : it turns the graph from a debugging tool into a
   governance instrument. Distinguishes human vs agent vs model-tool.
2. **Authority / delegation** — under whose grant the actor acted (a subagent
   acting on MY dispatch ; me acting in the session). This is where Q1's
   declared-role-vs-actual-actor resolves : the chain records the delegation, not
   just a static role.
3. **Integrity** — append-only, tamper-evident, so the trail is evidence, not
   convenience.

Why all three collapse into ONE arc : the causal graph is the shared spine, the
actor stamp is the hinge, append-only persistence is what makes either usable
beyond the current process. Spine without actor = replay but no accountability.
Actor without persisted chain = attribution for single events but no lineage.
Governance needs all three — the strongest argument for designing them together,
and against stuffing `role` into the event `data` map (gives the word "Miette" on
one event without the chain or integrity that make it mean anything).

### Q5 — integrity mechanism
Append-only + tamper-evident. Hash-chain each event to its predecessor (cheap,
Merkle-ish) ? Per-event signing (heavier) ? What threat model — detect
after-the-fact edits, or cryptographic non-repudiation ? Decide the integrity
guarantee's strength against its cost.

### Q6 — performance budget (HARD CONSTRAINT, Chris : "super performant")
Actor stamping + causation/correlation threading + integrity hashing must NOT
slow the hot dispatch path. Targets to settle : is persistence async/batched off
the dispatch thread ? Is the hash-chain incremental (O(1) per event) ? What is
the acceptable per-dispatch overhead budget (microseconds) ? The door already
adds a ~700ms registry lookup per native block — lineage must not compound the
in-band cost of the common path. Design persistence as a tail, not a barrier.

### Q7 — RESOLVED into the bigger frame below.
The earlier "legacy Ruby" reading was WRONG. Chris : Ruby is NOT legacy — Ruby
and Rust remain in parity. He wants ONE storehouse ; "Ruby and Rust operate on
the same door." So governance doesn't "extend to a second runtime" — there is no
second runtime. See the frame below ; it supersedes Q7.

---

## THE BIGGER FRAME — One Door (port), CommandBus default, storehouse as product adapter (Chris, 2026-06-16)

FRAME CORRECTION : storehouse is NOT "the door." The **door is the dispatch PORT**
(the command/query contract). Storehouse is ONE adapter behind it — the EMBRYONAUT
PRODUCT (warm socket daemon, persistence, governance lineage, MCP). The framework
itself ships a **simpler `CommandBus`** that does routing + wiring and works OUT OF
THE BOX, and the **standard adapter is CommandBus**.

This is the locked convention, exactly :
- **CommandBus = "it just works"** — runtime defaults to in-memory, the dispatch IS
  the act, no infra. The SUBSTRATE.
- **Storehouse adapter = "wiring is override, not substrate"** — swap in for the
  product-grade runtime : persisted, tamper-evident lineage, cross-process,
  cross-language single instance.

So "Ruby and Rust on the same door" = same PORT contract + same CommandBus routing
semantics, each in-process by default ; wire the storehouse adapter and "same door"
becomes literally ONE shared governed instance across both languages. The PRODUCT
makes it one process ; the FRAMEWORK makes it one contract. Event sourcing +
lineage live in the storehouse adapter, not the free CommandBus (see product-line
question below).

### Refinement (Chris) — two LAYERS, not two adapters
CommandBus and storehouse are not two adapters competing for one port. They are
TWO LAYERS :
- **LOCAL layer = CommandBus + hecksagons.** **ASYNCHRONOUS, eventually-consistent,
  simplest-possible** (Chris). The DOMAIN INTERIOR stays synchronous per the hexagon
  convention ("inside the boundary is synchronous, leaving is async") ; the BUS at
  the boundary is async + eventually consistent. Cheap because it PROMISES LITTLE :
  route the command, it gets handled, it eventually persists — no ordering beyond
  simple, no transactions, no governance. The hexagon wiring is HOW you plug in
  different adapters (persistence, payment, HTTP, cross-domain). Out-of-box runtime.
- **GLOBAL layer = storehouse.** Owns the **inbox** (durable async cross-boundary
  delivery — the outbox→pump→dispatch spine) and operates at global scope :
  governance, event sourcing, lineage. Sits ABOVE the local buses.
~~They meet at ONE hexagon edge (inbox/outbox handoff).~~ **RETRACTED — see
Further refinement below : the buses DO NOT interoperate. There is no handoff
edge. Each bluebook is assigned to ONE bus.**

**The real distinction is GUARANTEE STRENGTH, not sync-vs-async — BOTH buses are
async.** CommandBus : async + eventually-consistent + minimal. Storehouse : async
too, but durable, ordered, event-sourced, governed, tamper-evident.
**This is what structurally satisfies "super performant" :** you pick the bus PER
BLUEBOOK. A CommandBus bluebook is cheap because the bus is simple + eventually
consistent ; a storehouse bluebook pays for strong guarantees (actor stamp, causal
chain, integrity hash, durable ordered persistence). Performance is preserved by
CHOOSING the simple bus when you don't need the enterprise one — not by a
hot-path/cold-path split (that handoff framing is retracted ; no-interop, per‑bluebook
bus). Ruby/Rust : each runs CommandBus locally (own process, hexagon-wired) ; a
bluebook placed on storehouse runs against the one hosted enterprise bus.

### Further refinement (Chris) — bus is per-bluebook, NO interop, storehouse is hosted
- **Bus declared PER BLUEBOOK.** Default CommandBus (local, free, self-hostable) ;
  declare storehouse to put THAT bluebook on the enterprise bus. Bus = wiring
  ("wiring is override, not substrate").
- **The two buses are ISOLATED worlds.** A CommandBus bluebook and a storehouse
  bluebook do NOT share an event bus and do NOT dispatch across the boundary. No
  bridge to build or govern ; no leakage between a free local domain and the
  governed enterprise spine. (This RETRACTS the earlier "meet at one hexagon
  edge" handoff framing.)
- **Storehouse stays BEHIND EMBRYONAUT INFRA.** Not a vendored library ; a bluebook
  "on storehouse" runs against the hosted enterprise bus. The moat made
  operational : self-host CommandBus anywhere, but the org-scale governed bus is
  reached THROUGH Embryonaut infra. The no-interop rule keeps the free/paid
  boundary honest — you can't quietly stitch the free bus into the paid one.

**New open questions (decide-API-first, NOT now) :**
- **Q9 — WHERE is the bus declared? RESOLVED (Chris) : a DOMAIN-LEVEL hecksagon
  binding — a NEW attach level.** Today the hecksagon attaches at the AGGREGATE
  level (each aggregate's ports → adapters) ; we add a DOMAIN level (concerns that
  belong to the whole bluebook). The bus is the first inhabitant. Forcing argument :
  no-interop means a whole domain rides ONE bus, so per-aggregate bus selection
  would require cross-bus interop WITHIN a domain — forbidden. Bus therefore CANNOT
  be aggregate-level ; it MUST attach to the domain. The new level is required, not
  convenient. Grammar extension : the **Hexagon chapter** + the `Binding` IR
  (`rust/src/hecksagon_ir.rs` : today `aggregate, verb, adapter, on, success,
  failure`) need a DOMAIN-SCOPED binding variant (no `aggregate` field). Conceive
  the Hexagon bluebook FIRST, IR follows. Domain-wide adapters/policies could be
  later inhabitants of this level.
  - **The new level is a CASCADE (Chris).** Domain-level binding = the DEFAULT for
    every aggregate ; aggregate-level binding = the OVERRIDE. "Wiring is override,
    not substrate" made hierarchical (most-specific-wins). E.g. set persistence
    once at the domain ; the one aggregate needing a different store overrides it.
    **Ergonomic payoff (Chris) :** when a whole bluebook shares one persistence,
    today the hecksagon REPEATS the binding on every aggregate (N copies) ; the
    cascade collapses it to ONE domain-level line, aggregate blocks carry only what
    DIFFERS. Hecksagon shrinks to defaults-plus-exceptions ; the domain block reads
    as "whole bluebook persists to X, runs on bus Y" at a glance. Same trajectory as
    "family establishes world" / "adapter declares its handler" — push declarations
    up to where they're true once.
  - **Bus IS overridable too (Chris corrected my over-constraint).** Earlier claim
    "bus is a domain invariant" RETRACTED. The cascade is fully uniform : bus
    overrides exactly like persistence. An aggregate overriding to storehouse
    inside an otherwise-CommandBus domain is coherent AS LONG AS nothing dispatches
    across the seam — that one aggregate is just governed/event-sourced, the rest
    aren't. The invariant belongs on the INTERACTION, not the binding : **forbid
    cross-bus DISPATCH, not bus override.** So Q10's validator checks the true rule
    — "no aggregate or domain dispatches across a bus boundary" (intra- AND
    cross-domain) — which subsumes the old "no override" only WHEN a real crossing
    exists. Strictly more permissive + more uniform : the isolated override is
    legal ; only the genuinely incoherent crossing is caught.
- **Q10 — HOW is no-interop enforced?** A macrophage/validator forbidding cross-bus
  dispatch (a CommandBus bluebook referencing a storehouse bluebook's commands, or
  vice versa). Static check at conception time.

### Q8 — the product boundary : RESOLVED (Chris, 2026-06-16)
The line IS the local/global layer boundary, and it's the business model :
- **CommandBus + hecksagons → COMMUNITY / open.** Local, free, out-of-the-box ;
  "I'll let the community build that up" (the adapter ecosystem).
- **Storehouse → the EMBRYONAUT ADVANTAGE.** "An enterprise bus that can operate an
  entire enterprise." The global spine : governance, event sourcing, lineage,
  durable inbox, org-scale. Audit-grade, accountable, replayable, tamper-evident.
The moat : the framework is free and community-grown ; the thing that RUNS an
enterprise on one governed event-sourced bus is the product. So all of
role-on-event → causation/correlation → integrity lives in storehouse, by strategy,
not by accident of where code lands.

### Today (verified)
Ruby is a SECOND runtime : its own dispatch (`ruby/hecks/mixins/command/dispatch.rb`),
its own event bus (`ruby/hecks_multidomain/filtered_event_bus.rb`), its own
aggregate handles + projections. It shells to the `storehouse` binary only for
the `conception` CLI verb and `verify_parity`. Two implementations of the same
bluebook semantics, held in lockstep by the parity suite.

### The substrate ALREADY exists
`storehouse serve` runs as a **warm daemon on a Unix socket** (`run_serve/socket.rs`,
`UnixListener`, "warm daemon listening on {sock_path}") keeping parsed IR + state
warm in memory ; there is also a stdio transport (`run_serve/stdio.rs`). The door
can already be a long-lived interprocess service many clients dial. Performant by
construction (warm IR, socket round-trip, no per-call process spawn) — which is
how the "super performant" constraint is met.

### The move
Rip out Ruby's runtime ; give Ruby a **storehouse ADAPTER** — a hexagon adapter
whose dispatch port routes over the Unix socket to the one warm storehouse daemon
(the same `family`/`adapter`/`.hecksagon`/`.world` pattern as persistence/payment).
Ruby keeps being a LANGUAGE SURFACE and a PARSER (parse-parity stays) ; it stops
being a RUNTIME. Every Ruby command enters the identical door Rust + Miette use.

### Symmetry — an adapter for Rust too, WITHOUT a performance hit (Chris)
For consistency, Rust should ALSO reach the door through an adapter — not keep a
privileged in-process path while Ruby goes through one. Resolved by separating
PORT from TRANSPORT :
- **One door = one dispatch PORT** (the command contract). Ruby, Rust, Miette all
  compose a command and hand it to that port. This is the consistency.
- **Transport is an adapter detail chosen by LOCALITY.** Rust running INSIDE the
  warm daemon uses an **in-process / loopback adapter** — a thin pass-through that
  compiles to a direct `Runtime::dispatch` call : zero IPC, no hop, no perf hit.
  Ruby (separate process) uses the **Unix-socket adapter**. A remote client could
  use TCP. Same port, swappable transport.
This IS the locked principle "wiring is override, not substrate ; the domain
composes the call, the adapter runs it." The door is substrate ; transport is
override. Performance is preserved BECAUSE the adapter is swappable — you don't
pay for a socket you don't need.
**Build-time caveat :** verify the in-process adapter is a genuine zero-cost
pass-through, NOT an accidental serialize/deserialize round-trip through the
socket codec — that is the only place the perf hit could sneak back in.

### What it dissolves
- **Governance** — one door = one chokepoint. The hard-block made structural today
  extends to Ruby for free : Ruby has no native dispatch left to bypass it with.
- **Event sourcing + lineage** — ONE storehouse = one event log, one causal spine,
  one actor-attributed lineage. No second ledger, no governance-in-parity.
- **Parity** — does NOT evaporate ; it TRANSFORMS. Three layers today : (1) IR/parse
  parity (`verify_parity.rb` counts + `canonical_ir.rb`) — STAYS if Ruby keeps
  parsing (and may INVERT : storehouse becomes IR source-of-truth, Ruby matches,
  vs today's Ruby-IR-is-truth-Rust-projects) ; (2) behaviors parity — stays if both
  generate ; (3) runtime/dispatch parity (the `parity/fuzz` `ruby_dispatcher` +
  heki diff) — the ONLY layer one-storehouse touches, and it does not retire the
  concern, it RELOCATES it : from "do two engines agree?" to "does Ruby delegate
  EVERYTHING with zero residual in-process behavior?". See the parity-transform
  note below.
- **"Domain of domains, don't worry about the runtime"** — compose domains across
  languages ; none care who composed them, all dispatch to the one door. The
  self-hosting payoff falls out.

### The one real fork (decide-API-first, NOT now)
**The static-target story.** Ruby/Go have been STANDALONE generation targets
(deploy WITHOUT storehouse). "Ruby as a thin client of the one storehouse" is the
opposite of "Ruby as a self-contained deployable." They CAN coexist (governed
dev-runtime = the door ; static target = generated standalone), but the
relationship must be decided before anyone writes the storehouse adapter.

### Sequencing note
This frame is BIGGER than the event-sourcing arc and contains it. Likely order :
(1) decide the static-target fork ; (2) conceive the Ruby storehouse-adapter
hexagon (over the warm socket) ; (3) cut Ruby's runtime over to it ; (4) THEN the
enriched event envelope (actor + causation/correlation + integrity) lands once,
in the one storehouse, governing both languages. Fresh-head work — do not start
at high context.

## Governance tie-in (summary)

Lineage turns the GovernedDoor audit trail from a per-tool tally (`blocked_count`)
into a CHAIN : this actor, under this authority → dispatched this command → which
emitted this event → which triggered this reaction — append-only and provable. The
door already makes every act a bus event ; lineage makes every act *traceable to
its origin and attributable to an accountable actor*. That is full governance.
