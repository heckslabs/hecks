---
ref: restart-parser-in-bluebook-2026-06-13
status: open
category: session-restart
priority: high
posted_at: 2026-06-13
value: 'THE ARC : write the parser IN bluebook so Ruby + Rust both PROJECT from one declarative grammar and drift becomes structurally impossible (not merely parity-gated). GROUNDED + DURABLE this session : all 5 known-drifts retired (parity 426/426, known_drift.txt active list at ZERO) and the extraction grammar is CONCEIVED + validated + parity-clean at aggregates/language/grammar/extraction.bluebook (3 aggregates : Grammar -> BlockRule -> FieldRule). The conception is the LOCKED DESIGN, stress-tested against the three hard cases. NEXT (fresh head, gated worktree) : build the small kernel interpreter that READS extraction.bluebook to parse any bluebook, so parser.rs / parse_blocks.rs and the Ruby DSL builders both reduce to projections of it. SUBSUMES the retired hexagon-projection card : project rust/src/hecksagon_ir.rs from the bluebook (addendum-pt-8) and rust/examples/order_boundary/*.rs from pizzas.bluebook (Directive 2) are the SAME projection arc. Discipline : byte-precise kernel-floor ; parity + golden gates are the verifier ; never eyeball byte-equality ; never touch known_drift.txt without Chris. WHY fresh head : inventing the interpreter is DESIGN judgement parity cannot verify, and that judgement is what degrades at high context (this card was written at ~631k, exactly the boundary the discipline fences).'
---

# Session-restart handoff — write the parser in bluebook (2026-06-13)

Written at the tail of a ~631k session. Two things are DONE and durable; the
third is the arc, and it is byte-precise kernel-floor work that must run on a
clean, low-context head.

## DONE this session (committed on `order-boundary-reference`, do not redo)

1. **All 5 known-drifts retired — parity list at ZERO.** Full parity 426/426,
   exit 0, goldens 28/0, pizzas smoke green. Commits:
   - `9e37d916` — harry_wingate : strip trailing `# …` comments from attribute
     declarations (comment-aware) ; fixed in the parser PROJECTION
     (parser_helpers_shape + parse_blocks_shape), regenerated.
   - `387d38fa` — inbox : parse_aggregate now collects aggregate-NESTED
     policies and bubbles them to domain.policies (parser_shape).
   - `875dbf1e` — the three Ruby-side drifts : QueryRecorder gains an
     `attribute` recorder (voice_latency / storehouse_log) ; the vestigial
     `delivery :actor` keyword was DELETED from conductor.bluebook (it was in
     neither IR and selected a retired runtime fork — root removal, not
     accommodation).
   - (earlier in-session) the multi-line `vision` parser fix + hexagon vision
     rewrite — extract_string_spanning, the drift that proved hand-written
     parsers diverge by construction.

2. **The extraction grammar is CONCEIVED.** `aggregates/language/grammar/
   extraction.bluebook` — VALID (3 aggregates), parses byte-equal Ruby<->Rust,
   parity stays 426/426. This is the LOCKED DESIGN for the arc. It touches
   ZERO kernel files by design (the live parser stays at 426/426).

## The locked design (read extraction.bluebook — it is the source of truth)

The parser today has TWO layers:
- **Routing** (which keyword opens which block) — ALREADY data-driven via
  `BlockGrammar` in ir.rs. Routing never drifts, because it is data.
- **Extraction** (how a block's lines become IR fields) — still hand-authored
  TWICE : Rust `.rs.frag` functions (parse_attribute, parse_command …) AND
  Ruby DSL builders. **Every one of the 5 drifts lived in this layer.** That
  double authorship is the disease ; the drifts were symptoms.

The conception models the missing extraction layer as data :
`Grammar -> has_many BlockRule -> has_many FieldRule`. It is **stress-tested
against the three hard cases**, and the stress test is the whole point :
- `attribute` (flat, one line) — survives as flat FieldRules.
- `command` (nested : attribute / given / then_set / emits in its body) —
  FORCES recursion : `BlockRule.opens_block` + `BlockRule.contains` (child
  keywords) + a `nested_block` ReadStrategy. A flat field table is a toy here.
- `vision` (multi-line string literal) — FORCES a `string_spanning`
  ReadStrategy ; "read positional token N" cannot express a string that
  crosses physical lines (the exact drift fixed this session).

**Conclusion the design locks :** the extraction grammar must be (a) RECURSIVE
(blocks contain blocks) and (b) carry a ReadStrategy rich enough to include
string-spanning + nested-block, not just positional tokens. The flat shape
dies on cases 2 and 3.

## THE NEXT ARC — build the kernel interpreter (fresh head, gated worktree)

Build the small kernel interpreter that READS `extraction.bluebook` and parses
any bluebook from it — including extraction.bluebook itself (meta-circular).
Then `parser.rs` / `parse_blocks.rs` and the Ruby DSL builders both reduce to
projections of that one grammar, and Ruby<->Rust drift becomes **structurally
impossible**, not merely parity-gated. This is i66 / i649 kernel-minimization-
via-Futamura : the kernel shrinks to a small interpreter ; every block parser
becomes a residual after the grammar is specialized against.

**This card SUBSUMES the retired `hexagon-projection-2026-06-12` card.** Its
next-arc was "project the Rust IR/parser FROM the bluebook" — the SAME arc.
Folded in: regenerate `rust/src/hecksagon_ir.rs` from the bluebook
(addendum-pt-8 / i695 Phase 2), and make `rust/examples/order_boundary/*.rs` a
projection of `examples/pizzas/bluebook/pizzas.bluebook` (Directive 2). hexagon
bluebook itself is conceived + committed (c6f5f606) ; only the projection
remains.

## First concrete steps (clean head)
1. **Re-read `extraction.bluebook` end to end** — it is the locked design and
   carries the stress-test reasoning in its vision + comment block.
2. **Decide the interpreter's home** : one kernel interpreter both runtimes
   call, vs a projector that emits both parsers from the grammar. The former
   is the cleaner kernel-minimization end state ; ground the choice against
   the existing specializer pipeline before committing.
3. **Prove ONE block end-to-end** through the interpreter — start with
   `command` (the case that forces recursion), NOT `attribute` (the toy).
   If the grammar shape can't express it cleanly, that failure is the most
   valuable output — surface it, refine extraction.bluebook, don't design
   around the easy case.
4. **Gate every step** : `ruby -Iruby parity/parity_test.rb` staying 426/426
   (zero drift now — do not regress it) + goldens byte-identical + full
   `cargo` + `ruby -Iruby examples/pizzas/pizzas.rb` smoke.
5. **Never** eyeball byte-equality ; **never** add to `parity/known_drift.txt`
   without Chris (the list is at zero — keep it there).

## Discipline — why this is fenced for a fresh head
The drift fixes this session were safe at high context because they were
local, additive, and had an ORACLE (Ruby's output was already correct ; parity
proved byte-identity). This arc is different : it INVENTS an abstraction
(extraction-as-data) and a new interpreter. Parity checks output bytes ; it
CANNOT tell you the abstraction is sound. Design judgement is the risk, and
design judgement degrades at high context. Conception is safe at any context
(a design is human-reviewable before anyone implements it) ; cutting the
interpreter is not. Clean head, gated worktree, then build.
