---
ref: restart-adapter-trigger-result-grammar-2026-06-12
status: open
category: session-restart
priority: high
posted_at: 2026-06-12
value: 'Two LOCKED directives from Chris (2026-06-12, evening). (1) GRAMMAR GAP : trigger_on/result_into must carry through ALL adapter kinds, not just the driven/report family. Today :shell drops them silently (parser-parity proven : dump-hecksagon omits them). DESIGN LOCKED : LIFT both into ONE shared Subscription shape every adapter composes (NOT per-struct copies) ; existing per-kind trigger_on/response_into fields COLLAPSE into it, no compat shim. (2) Reframe the order_boundary Rust as GENERATED OUTPUT from pizzas.bluebook — not a standalone example. Bluebook is source of truth, Rust is what it compiles to ; show the full pipeline (bluebook validates → projects to this Rust → adapters wire at runtime). DO NOT retire it. Both are on branch order-boundary-reference / PR #734. Execute FRESH — parser-parity is kernel-floor, byte-precise, not a session-tail job.'
---

# Session-restart handoff — adapter trigger/result grammar + Rust-as-generated (2026-06-12)

Chris gave two directives after reviewing the pizzas async-boundary work
(PR #734, branch `order-boundary-reference`). Both are LOCKED. Execute
fresh — the parser change is the highest-stakes surface in the system.

## Context : what already landed on PR #734
- `examples/pizzas/hecks/pizzas.bluebook` — real Order gained Authorize/
  Decline (async verdict re-entering as plain commands) ; all bare
  primitives wrapped in VOs (file predated no-primitive-envy, was
  INVALID, now VALID). Commit 36801af7.
- `examples/pizzas/hecks/pizzas.hecksagon` — payment_gateway :shell
  adapter, trigger_on "OrderPlaced", result_into "Order.Authorize |
  Order.Decline", command bin/charge-gateway args [{{ref}} {{quantity}}].
- `examples/pizzas/hecks/pizzas.world` — gateway block (endpoint_env,
  token_env, timeout_ms, retries, backoff) + heki dir.
- `rust/examples/order_boundary/` — the handwritten Rust projection
  (domain.rs pure / ports.rs bridge / bus.rs sync pipeline / adapters/
  async workers / main.rs host). Currently framed as standalone ; an
  invented Order. Commit eeca182d + the check-references validate fix
  (2335b57d).

## DIRECTIVE 1 — trigger_on/result_into on ALL adapters (grammar gap)
Proven gap : `storehouse dump-hecksagon pizzas.hecksagon` shows the
shell_adapter WITHOUT trigger_on/result_into — the parser drops them.
Only the driven/report family + llm/compute/tts carry trigger_on today
(via response_into_target / driven-adapter parsing).

DESIGN — LOCKED (Chris, 2026-06-12) : LIFT trigger_on + result_into
into ONE shared adapter-subscription shape that every adapter kind
composes — NOT two fields copied onto each struct. One Subscription
value object (trigger_on: Option<String>, result_into: Option<String>,
+ effective-trigger helper) ; ShellAdapter / LlmAdapter / ComputeAdapter
/ TtsAdapter / ReportAdapter all hold a `subscription` rather than
repeating the fields. The existing per-kind trigger_on/response_into
fields COLLAPSE into it (migration : retire the duplicates, no
backward-compat shim — no first user). This is the big-refactor-
committed version, parity-gated.

Change surface (parity-gated, byte-precise) :
- `rust/src/hecksagon_ir.rs` — ShellAdapter struct (line ~268) gains
  `trigger_on: Option<String>` + `result_into: Option<String>` (+
  effective-trigger helper, mirroring LlmAdapter line ~341). Same for
  any other adapter kind missing them, OR the shared shape.
- `codegen/hecksagon_parser_shape/snippets/parse_shell_adapter_body.rs.frag`
  — parse the two keys (mirror parse_llm_adapter_body's `"trigger_on" =>`
  arm). Regenerate : `storehouse specialize hecksagon_parser --output
  rust/src/hecksagon_parser.rs`. GENERATED FILE — never hand-edit.
- dump-hecksagon canonical JSON arm (cli_dispatch_shape /
  arm_11_dump_hecksagon.rs.frag) — emit the new fields.
- Ruby mirror : `ruby/hecksagon/structure/shell_adapter.rb` +
  `ruby/hecksagon/dsl/shell_adapter_builder.rb` — add the accessors +
  builder keywords (mirror llm_adapter_builder.rb). The Ruby validator
  ALSO rejects {{}} in :command (fixed-binary rule) — already handled,
  placeholders live in args.
- GATE : `ruby -Iruby parity/hecksagon_parity_test.rb` must stay
  101/101 (Ruby ↔ Rust canonical JSON identical) ; full cargo ; pizzas
  smoke ; dump-hecksagon now SHOWS trigger_on/result_into on the
  payment_gateway adapter.
- THEN : runtime wiring — an event-triggered :shell adapter whose
  result_into routes the captured output back as Order.Authorize |
  Order.Decline. This is the live cascade (separate from the parse
  gap). Mirror how driven/report adapters fire on trigger_on.

## DIRECTIVE 2 — Rust projection = generated output, not standalone
Keep `rust/examples/order_boundary/` but reframe : it is what
`examples/pizzas/hecks/pizzas.bluebook` COMPILES TO, not a parallel
invented domain. No ambiguity about real-thing vs machinery.
- Re-anchor the Rust on the REAL pizzas Order (Pizza ref, CustomerName,
  Quantity, PaymentRef, OrderStatus, Authorize/Decline/CancelOrder) —
  rename the invented fields to match pizzas.bluebook exactly.
- Header every .rs : "GENERATED-STYLE PROJECTION of
  examples/pizzas/hecks/pizzas.bluebook — this is what the specializer
  should emit ; the bluebook is the source of truth."
- Show the full pipeline in the example README/doc : bluebook validates
  → projects to this Rust (domain pure / ports bridge / adapters async)
  → wires at runtime via the .hecksagon + .world.
- Ideal end state : the projection is literally emitted by a specializer
  from the bluebook, not handwritten. File that as the deeper arc.

## Why fresh, not now
Parser-parity is kernel-floor : a silent Ruby↔Rust drift poisons every
bluebook. The session that received these directives was at ~630k
context with the empty-dispatch loop pathology (the one that killed the
factories-phase-1 session). Per the restart discipline, byte-precise
parser work waits for a clean head in a gated worktree.

## LOCKED ADDENDUM — adapter/port as first-class DSL shape (2026-06-12, Chris)

The keystone that SUBSUMES both directives above. Decided after tracing the
muscle-memory pathology : the reflex wrote `domain.rs` by hand because a
handwritten adapter surface EXISTED to write into. Remove the surface.

1. **First-class DSL shape.** Adapter + port + the shared Subscription
   (`trigger_on` / `result_into`) are a first-class concept IN the bluebook
   DSL — declared, not handwritten. Directive 1's shared Subscription shape
   is PART of this shape, not a standalone parser patch.

2. **Projects to Rust.** The specializer EMITS the Rust ports/adapters (the
   `rust/examples/order_boundary/` tree) FROM that declaration. Directive 2's
   "order_boundary is generated, not standalone" is the projection target of
   this same shape. The two directives were always ONE arc.

3. **Kills the affordance.** Once adapters are declared-and-projected, no
   handwritten adapter surface exists → the imperative muscle memory (the one
   that wrote domain.rs ; the one that guessed `.state`) has nowhere to fire.
   Macrophage rule reduces to : adapters are DECLARED, never written.

4. **`mod` → adapters.** Most of the runtime's imperative `mod` impurities
   (heki persistence, file/shell/web edges, daemons) are adapter-shaped →
   rewrite them as declared adapters that project to Rust.

5. **Remove ALL exemptions to ZERO — pay now.** No standing exempt registry
   (the registry is itself debt — interest paid forever). Every
   `[antibody-exempt: …]`, the exempt registry, `known_drift.txt`, every
   `#[allow(...)]`, every `SKIP=` → driven to zero. The kernel bootstrap is
   NOT an exemption : it is a **Futamura fixed point** (the specializer emits
   itself, byte-identical — the meta-diagnostic-validator self-retirement
   proof-shape). So zero is LITERAL, not "zero except the seed."

6. **THEN always-enforce.** With a home for everything (declared adapter or
   generated domain) and zero exemptions, the macrophage flips to
   always-enforce — it can never lie ; every change passes clean or is
   genuinely wrong. Zero needs no case-by-case judgment ; that is the cake.

7. **One committed arc, clean worktree.** Pay in full in a single push off
   `order-boundary-reference`. Half-done is the WORST state (gate flipped over
   a half-built wall → exemptions creep back under pressure). Cake-later only
   if the arc completes. NOT a 630k tail job — clean head, gated worktree.

8. **The shape IS the hecksagon DSL — and hecksagon is itself a bluebook.**
   The first-class adapter / port / Subscription shape (points 1–2) is the
   hecksagon DSL. Hecksagon's grammar is written AS a bluebook in the grammar
   chapter (`aggregates/language/grammar/`), alongside `Bluebook` / `Sentence`
   / `Acl` / `Composition` / `Lexicon` / `Morphology` — which already describe
   themselves. TODAY there is NO `hecksagon.bluebook` ; the hecksagon DSL
   lives as handwritten `mod` (`hecksagon_parser.rs`, `hecksagon_ir.rs`,
   `ruby/hecksagon/*`, the parser frags). THAT handwritten parser is the
   impurity. Writing hecksagon-in-bluebook makes the parser GENERATED — the
   concrete instance of point 5's Futamura fixed point, not a gesture at it.
   The tower closes : adapter → declared in hecksagon → hecksagon defined in
   bluebook → bluebook defines itself. Self-hosting, all the way down. The
   bootstrap is a fixed point because hecksagon emits its own parser from its
   own self-description — nothing left to hand-write, nothing left to exempt.

## BINDING MODEL — the attach-resolved Subscription (2026-06-12, consolidated)

How the adapter binds to the aggregate. (Edges 1–2 are how it works today,
per Chris ; edges 3–6 are the model drawn forward — reasonable inference
from the pizzas case, VERIFY against real `hecksagon_ir` with a fresh head.)

1. **Runtime load-and-attach, NOT static compile.** The runtime LOADS the
   bluebook shape (aggregates × {events-out, commands-in, payloads}) at
   runtime and ATTACHES adapters to it live. This is the dynamic-runtime
   architecture — the bluebook is a held shape, not a compiled-away artifact.
   Do NOT reach for a static compile-time gate ; the binding is a runtime act.

2. **The attach is the checkpoint — not the fire.** OLD weakness : adapter
   attached BLIND, then FILTERED at fire time → a typo'd `trigger_on` matched
   nothing → silent dead path ("you could write nonsense and it just wouldn't
   fire"). FIX : the attach RESOLVES `trigger_on`/`result_into` against the
   shape it just loaded ; a non-resolving reference FAILS THE ATTACH, loudly,
   then — at wiring, not at fire. WHY it must be the attach : at fire time
   "didn't fire" is indistinguishable from "correctly didn't match" (one event,
   no context). Only the attach holds BOTH the full shape AND the full adapter
   spec — the one moment with enough information to tell nonsense from
   non-match. The filter model checks where it structurally cannot judge.

3. **The Subscription is one bidirectional unit — a round trip.** inbound
   (`trigger_on`) = an event the aggregate EMITS → adapter ; outbound
   (`result_into`) = the adapter's result → a command BACK INTO the aggregate.
   Shape : event out → impure work → command back in. Pizzas : `OrderPlaced`
   out → gateway charges → `Authorize | Decline` in. This is WHY Directive 1
   lifts both edges into ONE shared shape — they are one contract.

4. **`result_into "A | B"` is a discriminated union.** The impure outcome
   BRANCHES (success→Authorize, failure→Decline). ALL branches must resolve at
   attach ; the adapter result carries which branch was taken.

5. **Resolution is TYPING, not mere existence.** `trigger_on` resolves to the
   event's PAYLOAD (what the adapter receives) ; `result_into` resolves to each
   command's REQUIRED ATTRIBUTES (what the adapter must produce). The
   Subscription is a typed contract : adapter-in fits event-payload, adapter-out
   fits command-payload. Nonsense fails ; type-mismatched sense ALSO fails.

6. **One resolution, two payoffs — why resolve-at-attach and projects-to-Rust
   are the SAME design.** The resolution that makes nonsense loud-fail is the
   resolution that lets the projection emit TYPED Rust (the generated adapter
   knows `OrderPlaced`'s shape and `Authorize`'s attributes → typed glue, not
   stringly dispatch). Resolve once → safety AND typed projection. Directive 1
   (the shape) and Directive 2 (the projection) fuse into one mechanism.

7. **Portability falls out of it being a contract.** Same adapter spec attaches
   to DIFFERENT loaded bluebooks ; attach-resolution rejects loudly if a shape
   lacks what the adapter declares it needs. The adapter reads as a DEMAND on
   the aggregate : "I require an `OrderPlaced` event and an `Authorize`/`Decline`
   command pair." Portable, checked at every boundary.

8. **The resolver itself is declared, not coded.** With hecksagon-in-bluebook,
   the attach-resolution rule (`reference_to` must resolve against the loaded
   shape or the attach fails) is a VALIDATION RULE in the hecksagon bluebook,
   projected to Rust — not handwritten. Even the enforcement self-hosts. Same
   move as all of the above : the cure for soft-late-silent is
   hard-early-checked, and now the CHECKER is domain, not imperative.

## SURFACE SUPERSEDED — ports hang off the DSL (2026-06-12, locked with Chris)

The change-surface above (lift `trigger_on`/`result_into` into a shared
Subscription STRUCT, parse on the `:shell` arm) was the right IR mechanism but
the WRONG surface. Full locked design : `docs/designs/adapters-hang-off-the-dsl.md`.

The surface is NOT a struct with two fields. It is a PORT bound off the
aggregate FQN, filled by an ADAPTER that declares its FAMILY :

    Pizza::Orders.persisted_by('Heki')        # aggregate . port ( adapter )
    Pizza::Orders.charged_by('Shell', on: 'OrderPlaced', into: 'Authorize | Decline')

- **Two-color rule** : domain ALWAYS sync, adapters ALWAYS async. No async/sync
  keyword anywhere ; `delivery :sync/:actor` retires (the fork only existed
  because the color was a per-aggregate flag).
- **Ports hang off the FQN** as a third verb category beside `.Command` and
  `.snake_case`. No `adapter :shell do … end` surface to handwrite → the
  imperative muscle memory has nowhere to fire.
- **One round-trip = one port verb** ; effect ports carry `on:`/`into:`
  themselves (the Subscription is the port's own signature, not two struct
  fields).
- **hex declares the adapter → adapter declares its family → family groups
  explicitly-declared ports.** The bind resolves IFF the adapter's declared
  family contains the named port — the typed attach checkpoint.
- **Three files** : `.bluebook` domain (sync) / `.hecksagon` composition (verbs
  & ports, NO values) / `.world` configuration (every value).

Directive 1 (the Subscription) and Directive 2 (project to Rust) FUSE : the port
IS the declaration ; the typed round-trip it carries projects to typed async
Rust. Build still FRESH / gated per the discipline note above — this addendum
fixes the SHAPE the fresh head builds, not the timing.
