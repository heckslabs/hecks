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
