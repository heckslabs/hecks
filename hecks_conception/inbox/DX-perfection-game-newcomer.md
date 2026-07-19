# DX perfection game — Hecks as a new developer sees it (2026-06-29)

*A four-scout audit (onboarding, bluebook authoring, runtime/operator, architecture-vs-claims),
run against the real surface, distilled + calibrated by the resident. Captured so it survives a
context clear. NOT a commitment — a backlog to draw from. Sidetrack from the authz arc.*

## The one-line read
A beautiful README writing a check the tooling doesn't cash: the *concept* scores 7/10, the
*first-touch experience* scores 3/10, and the gap between them is almost entirely **silent
failure** + **broken `--help`** + **no first-hour path**.

## Scorecard (calibrated)
| Dimension | Score | Gap to 10 |
|---|---|---|
| Concept clarity (README) | 7 | build-time expectations + a verify step |
| Human onboarding (clone → first dispatch) | 3 | no SETUP.md, no minimal worked example |
| CLI self-documentation | 2 | `storehouse --help` is BROKEN — prints usage error, lists no commands |
| Bluebook/DSL learnability | 4 | then_set ops, block scopes, VO placement must be reverse-engineered |
| DSL reference for humans | 3 | grammar-is-a-bluebook is the IR contract, not a syntax tutorial |
| Validation correctness | 4 | real holes (see Tier 0), not just message quality |
| Editor support | 0 | no highlighting, no LSP, no .vscode/ |
| Runtime feedback / round-trip | 4 | "exit 0, 0 events" — no created ID, no event summary |
| Observability (events/cascade) | 5 | no newcomer-facing `events --follow` / cascade trace |
| Persistence transparency | 6 | .heki IS text (inspectable), but no blessed dev inspector |
| Claims vs reality (honesty) | 6 | system knows its gaps; framing not reconciled in public |

## The spine (recurring roots)
1. **Silent failure is the worst habit — and a STANDARDS violation** (validators-first, zero-bug):
   - typo'd keyword (`commnd`) parses clean; validator then complains about something unrelated
   - `reference_to NonExistentAggregate` ignored — no forward-reference check
   - `CreatePizza` with only `name` (description+price omitted, no defaults) dispatches exit 0
2. **Two hard breaks on first contact:**
   - `then_set bad_op:` → `thread 'main' panicked at parse_blocks.rs:1102` (panic on bad input = bug)
   - `storehouse --help` broken (cheapest, highest-leverage fix in the list)
3. **docs-are-the-bluebook has a blind spot: the human newcomer.** Right that the DOMAIN needs no
   prose; wrong that SYNTAX onboarding + operator discovery need none. Nothing exists for them.

## Calibrations (where scouts overshot)
- "description truncated to 'Classic'" — almost certainly the `k=v` CLI splitting on whitespace,
  NOT store corruption. Real DX bug (arg parser swallowed the tail), but confirm. The empty
  `ByDescription` result likely follows from it.
- ".heki is binary" — WRONG; text since the markdown migration. Persistence scores up.
- "200-line rule = 1/10" — too harsh (code-only rule + antibody + loc-ratchet + exempt markers).
  Real survivor: `rust/cli/src/main.rs` at 7,160 LoC is a genuine un-decomposed offender, distinct
  from deliberate kernel exempts.
- "self-hosting framing misleads" — the paper is explicit (bootstrapping ≠ strict). Framing
  reconciliation, not a lie.

## To a 10 — prioritized, cheap-first
**Tier 0 — bugs (zero-bug standard says fix-at-root):**
1. [DONE 2026-07-01] Fix `storehouse --help` to print the command list. (--help/-h/help exit 0 + list ; help_flag_test locks it)
2. [DONE 2026-07-02, hecks e6c9a3ed8] `then_set` panic → graceful validation error.
   Shipped exactly the recommended shape : Mutation IR gained `invalid_op: Option<String>`
   (parser records the bad op instead of panicking ; dump.rs emits only field/op/value →
   IR-dump parity byte-unchanged on valid corpus), a new rule
   `validator_mutations::invalid_mutation_op_errors` flags it in every validate path, and
   `interpreter::check_givens` refuses to dispatch an invalid-op command (no silent placeholder
   Set). 5 tests (2 validator, 2 runtime guard, 1 rewritten from the old #[should_panic]) ;
   full corpus clean ; cargo test --release + 152 behaviors + integrity green. NOTE : the sibling
   "rule-body parser panic-with-hint" (given/invariant unknown keyword, #3) uses the SAME shape
   and is now the obvious next fresh-head slice.
   ---- original finding (kept for provenance) ----
   Repro : a bluebook with `then_set :items, bogus_op: {…}` → `storehouse validate` PANICS
   (`thread 'main' panicked at src/parse_blocks.rs:1102`, EXIT 101, stack trace). The panic is
   DELIBERATE : the site comment says it "mirrors the rule-body parser's panic-with-hint rejection,
   and matches the Ruby DSL's `unknown keyword:` ArgumentError (parity : both runtimes reject it)."
   So the fix is NOT "stop panicking" — it is re-expressing "reject loudly" as a graceful
   validation error WITHOUT breaking Ruby/Rust IR-dump parity. parse_blocks is PANIC-BASED
   (parse_mutation returns Option, 0 Result-fns, 29 panics/unwraps). Recommended shape : add an
   invalid-op carrier to the Mutation IR (a field `#[serde(skip_serializing_if="Option::is_none")]`
   so valid-mutation dumps stay byte-identical → parity holds ; only invalid input, never
   parity-tested, differs), populate it instead of panicking, and flag it with a validator rule
   (reuse the validator_inside_refs pattern from #4). Then the runtime mutation applier must REJECT
   an invalid-op mutation, never silently skip. Architectural + parity-adjacent (specializer
   surface). FRESH-HEAD : do not start from a high-context session (verified 2026-07-01 : the
   deliberate-panic + parity constraint is exactly the design judgement parity can't verify).
3. Parser rejects unknown keywords with line + "did you mean". (same parser-error-model change as #2)
4. [DONE 2026-07-01] Validator forward-reference check (`reference_to` must resolve).
   The seam : `reference_to` is INSIDE-boundary (LegacyReferenceTo kind) — its universe is the
   single file, so a dangling target is provable with NO corpus, unlike the CROSS kinds
   (belongs_to / has_one / has_many) that retired the old per-file check. New rule
   `validator_inside_refs::dangling_inside_reference_errors` (LegacyReferenceTo only, qualified
   `from <Context>` skipped), wired into the BARE + BATCH validate paths only (corpus modes
   already resolve reference_to via unknown_aggregate_errors, so no double-report). 5 regression
   tests ; corpus swept clean (135/135 valid, 0 false-pos across conception + examples + miette).
5. Dispatch validates required attributes before applying. (blast radius — many commands may rely on
   lenient attrs ; corpus-wide check before tightening).
6. [REFUTED 2026-07-01] `k=v` whitespace-swallow — NOT a bug. Repro : dispatched
   `Menu::Dish.AddDish name='Spicy Thai Basil'` → `"id":"Spicy Thai Basil"`, full value intact.
   The scout's "description truncated to 'Classic'" was mis-passing args on their shell (an
   unquoted space), exactly as the reassessment suspected. No CLI-arg bug ; `ByDescription`'s
   empty result followed from the scout's own truncated input, not store corruption. Closed.

   *Reassessment 2026-07-01 : #1 shipped clean. #2–#6 are each MORE entangled than first sized —*
   *parser-error-model (#2,#3), reference-resolver (#4), dispatch-tightening blast radius (#5),*
   *unconfirmed (#6). None are clean session-tail fixes ; each wants a fresh head + a handoff prompt*
   *(like inbox/PROMPT-fix-pulse-pm.md). The cheap-safe wins (read-bypass, --help) are done.*

**Tier 1 — the first hour (~1–2 days):**
7. SETUP.md: rustc check → build ("~2 min on M1") → verify step → PATH → hooks.
8. FIRST_BLUEBOOK.md: 5-line domain authored → validated → dispatched → state read, real output.
9. Dispatch feedback: `✓ CreatePizza → Pizza#1 (Margherita, $15.00)` not "0 events".
10. `storehouse describe-command Domain::Aggregate.Command` (attrs, types, role, emits) — FQN discovery.
11. Human header atop both CLAUDE.md files: "documents the dev agent; humans see SETUP.md."

**Tier 2 — DSL & operator surface (~1 week):**
12. Standalone DSL reference GENERATED from the grammar IR (can't drift).
13. `storehouse events --follow` + cascade trace — make async adapter fires visible.
14. VS Code syntax highlighting (cheap); LSP later.

**Tier 3 — claims reconciliation:**
15. Decompose `main.rs` (7,160 → under the ratchet).
16. Exempt registry tying each `[antibody-exempt]` to reason + roadmap (so exempt ≠ silent debt).
17. Front-load honest framing (bluebook-first = direction; ~14K LoC kernel deliberately imperative;
    self-hosting = per-file byte-identity, full-binary is roadmap).

## Smallest visible win to start (when picked up)
`storehouse --help` + the silent-validation posture (Tier 0). One tight slice, one session,
bluebook-first (the fixes are validation rules). Felt difference is immediate; proves the pattern.
