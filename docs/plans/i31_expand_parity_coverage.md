# Plan — i31: expand parity coverage to full corpus

Source: inbox `i31` (Ilya P3 review, 2026-04-20).

Related items: `i8` (nursery parity gap — same gap, different framing), `i1`
/ `i2` / `i24` (DSL dialect collapse — resolved, PR #265), `i38` / `i39`
(fixture-parser escape divergence — resolved, PR #296).

## 1. Current state

`spec/parity/parity_test.rb` walks every `.bluebook` in the corpus through
both parsers, diffs the canonical IR, and classifies each result as hard
(blocks CI) or soft (reports only). Measured 2026-04-22:

| Section | Path | Count | Gate | Status |
|---|---|---|---|---|
| Synthetic | `spec/parity/bluebooks/*.bluebook` | 12 | hard | 12/12 ✓ |
| Real | `hecks_conception/aggregates/*.bluebook` | 41 | hard | 41/41 ✓ |
| Capabilities | `hecks_conception/capabilities/**/*.bluebook` | 33 | hard | 33/33 ✓ |
| Catalog | `hecks_conception/catalog/**/*.bluebook` | 20 | hard | 20/20 ✓ |
| Misc | `family/`, `applications/`, `actions/`, `chris/` | 19 | hard | 19/19 ✓ |
| **Hard subtotal** | | **125** | | **125/125 ✓** |
| Nursery | `hecks_conception/nursery/**/*.bluebook` | 375 | **soft** | 112/375 |
| Corpus total | | **500** | | **237/500** |

Ilya's concern: the hard gate protects only 25% of the corpus. The nursery
— 75% by file count, and the home of every domain LLM-drafted — is allowed
to drift with no CI consequence. Any new parser bug that trips only on
nursery-shaped inputs ships silently.

### Why nursery is soft today

The soft flag was added when the Ruby DSL parser could not load 302 of the
then-327 nursery files at all (the Symbol→Float/Integer bug tracked as
`i1`/`i2`). Hard-gating would have been a permanent red X against
pre-existing drift that no one intended to fix file-by-file. Soft was the
correct triage at that moment.

That moment has passed. `i1`/`i2`/`i24` collapsed the two DSL dialects in
PR #265 — 349 bluebooks migrated, ImplicitSyntax parser deleted. The
parity for *migrated* aggregates jumped from 140/490 → 227/490. But
nursery's file list was only partially swept, and the remaining failures
are no longer all one root cause.

## 2. What blocks hard coverage today

Fresh categorization of the 263 failing nursery files (2026-04-22 run):

| # | Category | What it means |
|---|---|---|
| 173 | Ruby syntax error | File still uses ImplicitSyntax forms — `list_of(X) :field`, PascalCase do-blocks without `command`/`value_object` keyword. The Ruby parser literally cannot `Kernel.load` these. |
| 28 | `list_of` string, not constant | File passes a string to `list_of("Foo")`; Ruby path wants bare constant `list_of(Foo)`. |
| 19 | `fixture` undefined inside aggregate | File declares `fixture "Name", ...` inside an aggregate block before the `fixture` DSL landed there (or in nursery files that predate it). |
| 19 | `reference_to` string, not constant | Same shape as `list_of` case — `reference_to "Thing"` rather than `reference_to Thing`. |
| 14 | `lifecycle` undefined on BluebookBuilder | File calls `lifecycle do ... end` at top-level; the Ruby DSL only supports lifecycle inside `aggregate`. |
| 5 | DSL arity mismatch | `wrong number of arguments (given 2, expected 1)` on various DSL calls. Small bucket. |
| 4 | Semantic drift | Both parsers load successfully; canonical IRs disagree. Example: `api_endpoint` Ruby output vs `a_p_i_endpoint` Rust output — abbreviation handling. |
| 1 | `event` undefined | Single outlier. |

**Only 4 of 263 are true semantic drift.** The remaining 259 are
*fixture-shape* problems: the nursery file uses DSL that the Rust parser
accepts (permissively) and the Ruby parser rejects (strictly). Same
dialect split that i24 was meant to close, lingering in the unswept part
of the corpus.

## 3. Unlock path

Three gates to clear before flipping nursery from soft to hard:

### Gate A — Close the dialect sweep (173 files)

The 173 syntax-error failures all trip on ImplicitSyntax forms that i24's
migration missed. Mechanical: for each file, rewrite

```
list_of(TargetingRule) :targeting_rules     →   attribute :targeting_rules, list_of(TargetingRule)
Campaign do                                 →   command "Campaign" do         (if it has command shape)
TargetingRule do                            →   value_object "TargetingRule" do  (if it has VO shape)
```

Rule of thumb: any PascalCase do-block with `reference_to` / `then_set` /
`emits` is a command; PascalCase do-block with only attributes is a
value-object. i24's migration used this exact disambiguation.

Execution: a Ruby script under `tools/` (not shell; not Python — see i37)
that ASTs or line-sweeps the 173 files. Run in a batch PR; spot-check 20
before/after and let the parity suite confirm the rest.

### Gate B — Normalize strict-mode DSL arguments (66 files)

The three "string not constant" buckets (28 + 19 + 19 = 66) share root
cause: Ruby's strict DSL rejects strings where a constant is expected. A
one-time rewrite over the affected files:

- `list_of("Foo")` → `list_of(Foo)`
- `reference_to "Foo"` → `reference_to Foo`

These *could* be fixed by relaxing Ruby's validator to coerce strings →
constant lookup, but Chris's established preference is **strict over
permissive** (see the i24 resolution: delete ImplicitSyntax, don't extend
it). Rewrite the files.

### Gate C — Cover missing DSL methods (33 files)

The `fixture`-inside-aggregate, top-level `lifecycle`, arity, and `event`
buckets (19 + 14 + 5 + 1 = 39, allowing overlap ~33 files) are legitimate
DSL gaps in the Ruby path that Rust parses fine. Two options per bucket:

- **Implement in Ruby** — add the missing DSL method to `AggregateBuilder`
  / `BluebookBuilder` to match Rust. This is the "Ruby catches up" path,
  appropriate when the Rust surface is the canon.
- **Reject in Rust** — if the DSL shape is accidental and should be a
  parse error in both runtimes, tighten Rust instead. Only applies where
  the grammar was never designed to allow the form.

Most of the `fixture` / `lifecycle` cases are the first kind — the nursery
files intentionally use these. Plan: implement in Ruby. ~80 LoC guessed
across the builders; touches `lib/hecks/dsl/aggregate_builder.rb` and
`lib/hecks/dsl/bluebook_builder.rb`.

### Gate D — Resolve the 4 real drift cases

Investigate each. The visible one is abbreviation handling
(`api` → `api_endpoint` vs `a_p_i_endpoint`) — a canonical-IR
normalization bug on one side. Two or three will be known fixture-oddity;
one or two may need known-drift entries if the fix is disproportionate.

## 4. The flip

When A + B + C + D land (or A + B + C land and D reduces to N known-drift
entries ≤5):

1. Edit `spec/parity/parity_test.rb` — remove `soft: true` from the
   nursery `section(...)` call. Re-run the suite.
2. The pre-commit hook (`bin/pre-commit`, runs
   `ruby -Ilib spec/parity/parity_test.rb`) now blocks on any nursery
   drift. Any nursery bluebook that fails parity aborts a commit.
3. `known_drift.txt` becomes the escape hatch for intentional cases
   (same as today for synthetic/real sections).

### Effect on future bugs

- Parser bug that breaks `fixture`-in-aggregate? Nursery has 19 files
  using that shape; at least one fails; hard CI stops the PR.
- Canonical-IR normalizer regression (like the `api` abbreviation)? 500
  files run through both runtimes; the cluster that exercises the
  regression catches it.
- New nursery file that uses a non-existent-in-Ruby DSL method? Fails
  parity *before* it lands, driving either implementation in Ruby or the
  file gets rejected at review.

The nursery becomes a **corpus-sized contract test** instead of a
95%-visibility suggestion.

## 5. Tie-in to i8

`i8` (Ilya, 2026-04-20) asked the same question with a different framing:

> Parity test nursery coverage gap: 350 nursery bluebooks (75% of corpus)
> are excluded from Ruby↔Rust parser parity … A nursery-parser bug could
> ship without detection. Options: (a) run all 350 per CI — ~18s extra,
> probably fine; (b) 10-20 random sample per run — flaky but rotates
> through corpus; (c) random + sticky. Recommend (a).

i8's recommendation (run all) is already the shape i31 delivers. i8
covers the same gap in `behaviors_parity_test.rb` and
`fixtures_parity_test.rb` — those suites today cover only hardcoded
samples. Treat i8's behaviors + fixtures scope as a follow-up:

- Extend `behaviors_parity_test.rb` to walk every `.behaviors` under
  `hecks_conception/` (currently 3 hardcoded samples).
- Extend `fixtures_parity_test.rb` to walk every `.fixtures` under
  `hecks_conception/` (already partially expanded; 349/359 reported).
- Same soft→hard flip once the corresponding gaps close.

Mark `i8` done after this plan ships the `.bluebook` side; re-file the
behaviors/fixtures side if they haven't caught up organically.

## 6. Commit sequence

Rough shape — two to three feature PRs, plus the flip:

1. **`tools: nursery dialect sweep (ImplicitSyntax → explicit)`** — adds
   `bin/nursery-parity-sweep` (the "sweep tool"; see
   [`docs/usage/nursery_parity_sweep.md`](../usage/nursery_parity_sweep.md)),
   runs it over the nursery, commits the rewritten bluebooks. Parity
   suite reports significantly fewer blocking failures. The tool covers
   Gate A *and* Gate B in one pass (reference_to / list_of string→const,
   list_of swap, list_of inline block → sibling value_object). *~250 LoC
   Ruby; idempotent; safe to rerun after any nursery addition.*

2. **`tools: nursery strict-mode normalization (list_of / reference_to)`**
   — same pattern for the 66 string-not-const files. Can ride in PR 1
   if the sweep tool handles both transforms. *~400 LoC of rewrites.*

3. **`dsl: implement fixture/lifecycle/event DSL methods in Ruby`** —
   ~80 LoC additions to `AggregateBuilder` + `BluebookBuilder` so the
   Ruby parser accepts the 33 fixture/lifecycle/event/arity shapes.
   Parity drops to ~4 drift.

4. **`parity: investigate + fix the remaining real drift`** — address the
   4 true drift cases (abbreviation handling, etc.). Small diff, mostly
   in `canonical_ir.rb` or `hecks_life/src/dump.rs` or targeted nursery
   edits.

5. **`parity: flip nursery from soft to hard gate`** — one-line edit to
   `parity_test.rb`. Summary line in the test output changes from
   `263 soft drift (does not fail CI)` to
   `500/500 match` (or `N known drift (allowed)` if any remain).

Steps 1 + 2 can be one commit if the sweep tool handles both. Steps 3 +
4 can be one if the investigations are quick. Realistic: 3 commits total.

## 7. Risks

- **False drift from incidental formatting.** The Rust parser normalizes
  some whitespace/ordering that the Ruby parser preserves verbatim (or
  vice versa). The canonical IR layer exists precisely to erase that, but
  any new DSL surface added in step 3 needs a matching canonical-IR
  entry on both sides or it becomes permanent drift. *Mitigation*: each
  new DSL method in step 3 gets a spec/parity/bluebooks/ synthetic
  fixture proving parity before the nursery sweep runs.

- **Sweep tool introduces regressions.** A mechanical rewrite that
  misreads a file can turn "Ruby can't parse" into "both parse but
  disagree" — worse, because soft flags hid the first class and now
  nursery is hard. *Mitigation*: dry-run the sweep on 20 files, diff,
  human-review, then run on the rest. Spot-check 10% post-sweep. Parity
  suite is the ultimate verifier.

- **Performance regression at CI time.** 500 files × 2 runtimes × IR diff
  ≈ 18-25 seconds on current hardware (i8 estimated 18s for nursery
  alone). Pre-commit hook already runs the suite; acceptable on dev
  laptops (verified today: ~12s on M-class). *Mitigation*: if it
  balloons, shard the nursery section and run in parallel (Open3 pool),
  or split nursery-hard vs nursery-soft-on-dialect-edges.

- **Nursery churn pressure.** Nursery is where LLM-drafted domains land
  for iteration. If every draft must parity-pass, the friction for
  experimentation goes up. *Mitigation*: known_drift.txt is the escape
  hatch — adding a line is a 2-second PR. Frame nursery-hard as "new
  drafts must either parse in both runtimes or explicitly opt out".

- **Coverage false sense of security.** 500/500 parity is not semantic
  parity — it's parser+IR parity. Two runtimes could agree on the IR and
  disagree at dispatch time. `behaviors_parity_test.rb` covers some of
  that; full dispatch parity is a separate initiative (see i30
  differential fuzzer plan).

## 8. Key files

- `spec/parity/parity_test.rb` — the suite; one-line flip at the end.
- `spec/parity/known_drift.txt` — escape hatch list.
- `spec/parity/canonical_ir.rb` — Ruby side of the IR normalizer.
- `hecks_life/src/dump.rs` — Rust side.
- `lib/hecks/dsl/aggregate_builder.rb` — gets `fixture`, `lifecycle`,
  `event` DSL methods (step 3).
- `lib/hecks/dsl/bluebook_builder.rb` — gets top-level `lifecycle` (step 3).
- `bin/nursery-parity-sweep` — the sweep tool; step 1+2 in one pass.
- `docs/usage/nursery_parity_sweep.md` — runbook for the sweep tool.
- `spec/tools/nursery_parity_sweep_spec.rb` — smoke test for the tool.
- `hecks_conception/nursery/**/*.bluebook` — 173 + 66 ≈ 239 files
  rewritten mechanically.

## 9. Key answers

- **Is i1/i2 still blocking?** No. Resolved by PR #265 (`i24` DSL
  collapse). The remaining 263 nursery failures are the unswept files,
  not the parser bug. Inbox `i1`/`i2` are both `status: done`.

- **Is i38/i39 (fixture escape) still blocking?** No. Resolved by PR #296
  in this session. `fixtures_parity_test.rb` moved from 345/358 to
  349/359; the escape expander guards it.

- **Does this need a random-sample scheme?** No. The full corpus runs in
  ~12-25 seconds and the pre-commit hook already tolerates it. i8's
  option (a) ("run all") is the right answer; random sampling reintroduces
  flakiness and hides drift on whichever 80% the sample missed.

- **How long to ship?** Steps 1+2 dominate — mechanical rewrite of ~240
  files. Tool authoring + dry-run + verify: ~3-4 hours focused. Step 3
  is ~1 hour of DSL additions. Step 4 is open-ended but bounded by 4
  files. Realistically: a day's work, one to two sessions.
