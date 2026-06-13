---
ref: restart-hexagon-projection-2026-06-12
status: open
category: session-restart
priority: high
posted_at: 2026-06-12
value: 'hexagon.bluebook is CONCEIVED + committed (c6f5f606, branch order-boundary-reference) — the source of truth for a domain''s boundary wiring (Hexagon/Family/Field/Adapter/Binding), passing validate + 7 behaviors + parity. NEXT ARC (do this fresh) : project the Rust IR/parser FROM the bluebook, not hand-written. PROOF it must be a projection : committing the bluebook tripped the Ruby<->Rust parity gate — the hand-written Rust parser returned vision:null on a long multi-line vision while Ruby parsed it. Hand-written parsers diverge by construction ; one projected source cannot. This fuses addendum-pt-8 (regen rust/src/hecksagon_ir.rs from the bluebook) + Directive 2 (order_boundary/*.rs becomes a projection of pizzas.bluebook). Byte-precise kernel-floor : gated worktree, parity/golden gates as the verifier, never eyeball byte-equality, never touch known_drift.txt without Chris.'
---

# Session-restart handoff — project the Rust from the hexagon bluebook (2026-06-12)

Written at the tail of a ~631k session that CONCEIVED the hexagon bluebook with
Chris. The conception is done and committed ; the projection is the next arc and
is byte-precise kernel-floor work that must run on a clean head.

## DONE this session (committed, do not redo)
- `hecks_conception/aggregates/language/grammar/hexagon.bluebook` + `.behaviors`
  — the hexagon grammar chapter. Commit **c6f5f606** on `order-boundary-reference`.
  Passes `storehouse validate` (5 aggregates), behaviors (7/0/0), and parity
  (`ruby -Iruby parity/parity_test.rb` = 421/426, all 5 non-matches pre-existing
  known-drift).
- Design doc `docs/designs/adapters-hang-off-the-dsl.md` — the **CONCEIVED**
  section at the end is the final model ; EARLIER sections still show a
  superseded `into` FQN on the binding. **The bluebook wins** over the prose.
- The earlier restart card `adapter-trigger-result-grammar-2026-06-12.md` has a
  `SURFACE SUPERSEDED` addendum pointing at the design.

## The model (source of truth = hexagon.bluebook)
- **Hexagon** (root) : `domain`, `has_many Binding` ; commands `Conceive`,
  `Verify` (OPTIONAL startup fail-fast over runtime discovery).
- **Family** : `name`, `verb` (the how-verb, e.g. `persisted_by`), `signal`
  (reply | effect), `has_many Field`.
- **Field** : one config field NAME (value lives in `.world`).
- **Adapter** : `name`, `belongs_to Family`. **No FQN** — the adapter declaration
  already knows which domain it routes to.
- **Binding** : `aggregate` (own-domain port), `on` (triggering event),
  `has_one Adapter`. References ONLY its own domain.
- **Rules** : single-direction relationships (**never bidirectional**) ; **no
  `list_of`** (collections are `has_many`) ; an adapter is anything **OUTSIDE
  the domain boundary** (persistence, HTTP, calling another bluebook) ;
  cross-domain routed through **storehouse at runtime** ; domain always sync,
  adapters always async, colour never declared ; a bluebook never references
  another bluebook directly — the adapter is the indirection.

## THE NEXT ARC — project the Rust, don't hand-write it
Chris (2026-06-12) : “this should be a projection — not hand written.” The Rust
IR/parser AND the `order_boundary` Rust should be PROJECTIONS of the bluebook.
**Proof it must be** : committing `hexagon.bluebook` tripped the Ruby<->Rust
parity gate — the hand-written Rust parser returned `vision: null` on a long
multi-line vision while Ruby parsed the full string. Hand-written parsers
diverge by construction ; a single projected source cannot. This fuses :
- **addendum pt 8** (i695 Phase 2) : regenerate `rust/src/hecksagon_ir.rs` (and
  the parser) FROM `aggregates/framework/hecksagon/hecksagon_ir.bluebook` — and
  now also from `hexagon.bluebook`.
- **Directive 2** : `rust/examples/order_boundary/*.rs` becomes a projection of
  `examples/pizzas/hecks/pizzas.bluebook`, not a standalone hand-written tree.

Both now have what they lacked : the **source bluebook to project from**.

## KNOWN parser gap surfaced (real — the projection should fix it)
The Rust hecksagon/bluebook parser returns `vision: null` for long multi-line
visions (backticks, arrows, multiple paragraphs) ; Ruby parses them. Worked
around in `hexagon.bluebook` by a SHORT one-line vision with the detail moved
to a `#` comment block. **This workaround is not the standard** — when the
parser is projected from the bluebook it should handle full visions ; the short
vision is only there to keep the parity gate green until then.

## First concrete steps (fresh head, gated worktree)
1. **Orient on the specializer** : `storehouse specialize` targets ; the
   `codegen/*_shape/` dirs and `.rs.frag` snippets ; the goldens + how byte-
   identity is checked. The earlier card cites
   `storehouse specialize hecksagon_parser --output rust/src/hecksagon_parser.rs`.
2. **Answer the gating question** : is there already a bluebook->Rust-struct
   projector to point at `hexagon.bluebook`, or is Phase 2 genuinely unbuilt
   (so the first deliverable is BUILDING that projector)? Get the honest answer
   with evidence before writing anything.
3. **Project**, gating on : `ruby -Iruby parity/parity_test.rb` staying clean
   (>= 421/426, 5 known-drift) + the goldens byte-identical + full `cargo` +
   `ruby -Iruby examples/pizzas/pizzas.rb` smoke.
4. **Never** eyeball byte-equality — run the parity/golden gates. **Never** add
   to `parity/known_drift.txt` without Chris (let the gate block, report, he
   decides per file).

## Discipline
Byte-precise kernel-floor : a silent Ruby<->Rust drift poisons every bluebook.
Single committed arc off `order-boundary-reference`. This card exists BECAUSE
the conceiving session ran to 631k — exactly the context the parser-parity
discipline fences off. Clean head, gated worktree, then build.

## Arc tail (after the projection lands) — folded in from the retired grammar card
Once adapters are declared-and-projected (no hand-written adapter surface left) :
- **mod -> adapters.** Most of the runtime's imperative `mod` impurities (heki
  persistence, file/shell/web edges, daemons) are adapter-shaped — rewrite them
  as declared adapters that project to Rust.
- **Drive ALL exemptions to ZERO.** Every `[antibody-exempt: …]`, the exempt
  registry, `parity/known_drift.txt`, every `#[allow(...)]`, every `SKIP=` — to
  zero. The kernel bootstrap is NOT an exemption : it is a Futamura fixed point
  (the specializer emits itself byte-identical). Zero is LITERAL.
- **THEN always-enforce.** With a home for everything (declared adapter or
  generated domain) and zero exemptions, the macrophage flips to always-enforce
  — it can never lie. (Keystone of the retired `adapter-trigger-result-grammar`
  card, addendum pts 4–6, folded here so that card can go.)
