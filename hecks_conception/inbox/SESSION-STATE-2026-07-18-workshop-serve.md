# SESSION STATE — 2026-07-18 workshop-serve marathon (for the fresh head after /clear)

## LANDED on main (committed + merged)
- `feat(serve)` workshop experience : live records, record-browser picker, hot reload, HTTP-door 400s.
- `feat(runtime)` payload gate (the ACL) : VO invariants bite, required attrs, reference counter-mint closed. All doors, one chokepoint.
- `feat(grammar)` the Bluebook is Ruby — valid Ruby is a design constraint ; `enum:`/space-form retired ; known_drift EMPTY.
- `feat(grammar)` one_of — closed value sets (scalar + whole-value members) ; `enum:` migrated across ALL repos ; parity 388/388.
- `feat(projection)` JSON Schema per command ; the served form renders FROM the schema (one contract).

## UNCOMMITTED on main (real code, on disk, survives /clear — COMMIT NEXT)
- invariant → `minimum`/`maximum` in json_schema.rs ; form renders `min`/`max`.
- MONEY : cents-wrapper VOs marked `x-hecks-money` ; form displays DOLLARS (÷100, step 0.01), submit converts ×100 ; wire stays cents.
- RAW SOURCE VIEW : `GET /domains/{d}/source` (multi.rs, OnceLock SERVED_ROOT) + `< /> view bluebook source` button (html_domain.rs).
- `json_str` ROOT FIX (json_helpers.rs) : proper JSON escaping (was quote-only — latent bug ; multi-line values emitted invalid JSON).
- toolshed.bluebook : `availability` (one_of available/out + transitions) + CheckOut/CheckIn + `Available` query + borrow/return POLICIES. Validated + live-verified (borrow flips a tool to `out`).
- Files touched : rust/src/projection/json_schema.rs, server/html_form.rs, server/html_wizard.rs, server/html_domain.rs, server/multi.rs, server/routes.rs, json_helpers.rs, examples/workshop_demo/toolshed.bluebook.

## Standards added (miette_family/chris_young/standards.md — UNCOMMITTED, renders into my prompt on boot)
- **Trust the tiered gate** — never hand-run CI's sweep ; fast path during work, hooks + CI gate the commit.
- **Route through the batching adapters** — loop is model-bound ; shell batches execution, Explore subagent batches recon.
- **The bluebook holds only the SME's ubiquitous language** — the foundational one ; framework substrate never in the domain.

## OPEN arc cards (inbox/)
- `PLAN-outbox-as-middleware-not-injection.md` — stop injecting OutboundEvent into user domains ; make it shared middleware (like the gates). Grounded in a full recon ; the seam is `mod.rs:434` (delete injection) + `mod.rs:1250` (drain → after-gate). KERNEL-FLOOR.
- `VALIDATOR-cross-aggregate-policy-ref-naming.md` — silent-wrong-tool bug from unaligned reference names ; needs a validate-time rule.
- `GRAMMAR-one-of` / `PLAN-payload-gate-acl` / `PLAN-json-schema-projection` — all LANDED (ledgers inside).

## Small follow-ons noted, not done
- Wire the served shelf list to `Tool.Available` (page shows only available tools).
- Records table : show money as `$2.00` not `200` ; JPY minor_units:0 (no ÷100).
- MCP door : per-command inputSchema from the schema projection (`storehouse schema` CLI already exists ; Node splice in tooling/storehouse-mcp).
- Browser-only checks : money ×100 submit, the `<pre>` source render.

## Method proven this session (the meta-win)
The loop is MODEL-BOUND, not compute-bound (measured : builds ~1.7s, single-file storehouse cmds 0.00s). Turn-count is the cost. Levers : fat Bash dispatches (build && test && curl), Explore subagents for recon (a 12-file map = 1 round-trip), trust the tiered gate. Two kernel arcs (outbox, ref-naming) got fully DESIGNED via subagent recon without touching kernel code from memory.
