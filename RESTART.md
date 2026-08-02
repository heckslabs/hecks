# Restart prompt — hecksagain, projecting the parser

Paste this into a fresh session. Read `README.md` first, then this. `HANDOVER.md` is
gone — its opening claim ("Do not call Rust a projection. Nothing generates it") had
been false for a week, and a handover wrong in its first paragraph is worse than none.
Everything from it still worth having is in "Findings worth not rediscovering" at the
bottom of this file; the original is in git history if you want the rest.

---

## Where things stand

`main` at `874a8fe`, 8 commits ahead of `origin/main`, not yet pushed. Working tree
clean, but this repo has had a SECOND concurrent session active on it (its commits are
interleaved with the ones this file otherwise describes — `457bc96`, `1dd3224`) ; check
`git log` rather than trusting this file's account of exactly what landed when. Gates:

    bundle exec rspec                             754 examples, 0 failures
    cd rust && cargo test --release --workspace   passing, 0 warnings
    bin/parity                                    AGREED, 15 stages, 120 mutants

`core.hooksPath` is LOCAL config — a fresh clone needs
`git config core.hooksPath .githooks` or the pre-push parity gate is silent.

## THE NEXT TASK — the blocker is gone, the parser is not

**Goal: project the PARSER from the language.** That is where the value is — the
shapes projection buys almost nothing (see "what the projection is actually worth"
below), and every bug this arc found lived in hand-written parsing and reading.

**The blocker was that the language declared SHAPE and not SPELLING.** It does both
now. `lib/hecksagain/language/bluebook/syntax.bluebook` declares a `Syntax` aggregate
holding two closed sets — `Keyword` (77 rows: the word, the body it may be typed in,
what block it opens, the category it declares, the field it fills) and `Argument` (120
rows: positional or named, what it looks like typed, required or not, what it fills) —
plus `Context`, `Body` and `ArgumentKind` for the cells to admit into.

**No commands, on purpose**, the same reading as `Vocabulary` beside it: a domain does
not declare its own syntax, so nothing dispatches this, `Plan` skips it by
construction, and it costs nothing in the judge or in `WholeBluebook`. `bin/ir_structs`
subtracts it beside `Vocabulary` and `Member`, with the reason in the header.

`spec/syntax_conformance_spec.rb` is what keeps it from being decoration — 38 examples
reading the declaration out of the IR and holding the live builders to it IN BOTH
DIRECTIONS. Probed, not assumed: a declared word no builder answers goes red, a builder
grown a word the language does not declare goes red, a `fills` naming a field that does
not exist goes red, a keyword argument the builder takes and the language omits goes
red.

### What writing it found (the value was in the audit, as predicted)

- **`strict_boot.rs`'s near-miss list is wrong, in the dangerous direction.** Five of
  its twelve block keywords are not words of the language at aggregate-body level —
  `view`, `rule`, `factory`, `create` are words this Ruby never had, and `invariant` is
  a real word in the WRONG BODY (a value object, not an aggregate). A word ON that list
  is treated as KNOWN and passed, so `factory do` is waved through by the check that
  exists to catch it. Pinned as `NEAR_MISS_DIVERGENCE` in the conformance spec;
  shrinking that constant is the fix.
- **`identified_by :sequence` is admitted by both builders and refused by the
  language.** `EntityBuilder`'s own comment advertises it ("names the attribute and lets
  the whole value object stand as the id"); `Identify`'s given asks that a part reach a
  scalar (`include?(".") || include?("_id")`), which a bare symbol does not. The form is
  declared because the surface admits it. The comment is stale.
- **`one_of` means two different things and one of them is unreachable.**
  `ValueObjectBuilder` defines `one_of(&block)` over `AttributeCollector`'s
  `one_of(*values)`, so inside a value-object body the inline type form is shadowed and
  `attribute :size, one_of("small", "large")` raises. Legal at aggregate level, illegal
  one level in, and nothing said so.
- **`member` outside `one_of` is accepted.** `one_of` instance_evals its block on the
  builder itself, so the nesting is a convention of the spelling that the host-language
  builder cannot enforce — and a parser projected from these rows would.
- **A read model's filters are options where an ask's are fields.** Same three words
  (`where`, `order_by`, `limit`), same builder module, different landing. That was a
  comment in `readings.rb`; it is a column now.

### The next rung, done — twice over

`bin/ir_syntax` projects `Syntax::Keyword`, filtered to `context: "Aggregate"`, into
`rust/src/bluebook/ir_syntax.rs`'s `AGGREGATE_KEYWORDS`. `runtime::strict_boot` reads
it from there instead of carrying its own copy. `spec/ir_syntax_export_spec.rb` holds
the checked-in file to the generator ; `spec/syntax_conformance_spec.rb`'s last example
holds the generator's own selection rule to exactly what got projected, so a change to
either without the other goes red.

**First pass** — just the seven words that open a `do` block (`command`, `entity`,
`identified_by`, `lifecycle`, `policy`, `query`, `value_object`), replacing a
hand-written twelve-word list that had drifted: five of its words (`view`, `rule`,
`factory`, `create`, `invariant` — real, but typed in a value object, not an
aggregate) were not language keywords at all, so each was treated as KNOWN and passed
straight through the check meant to catch a typo of one.

**Second pass** — widened to all ten words the language admits at aggregate-body
level, block-opening or not. The first pass only checked lines ending in `do`, so a
typo of `attribute`, `description`, or the bare-symbol form of `identified_by` fell
through the same hole silently. The scan now checks every non-blank, non-comment
line at depth zero.

**Probed both times, not just built green.** First: a `factory do … end` block used
to be silently treated as KNOWN (on the old hand-written list) and so was immune to
the check meant to catch exactly this — it now falls through to the PRE-EXISTING,
NAMED gap instead (the parser silently drops a construct it does not recognize, same
as any other alien word), which is the honest failure mode and not a new one. Second:
confirmed `atribute :cost, Money` now refuses at boot with a suggestion
(`rust/tests/strict_boot_test.rs` carries both cases as permanent regressions).
Fixing the silent-drop gap itself — full load/refuse parity — is a different, larger
task, named in `strict_boot`'s own doc comment, and was not attempted here.

`bin/ir_structs`'s emitted header stays the map of where the language still comes up
short (`Lifecycle`, `OrderBy`, `Direction`, `LimitSpec`, `ValueSpec` have no language
source; `Query.limit`, `ValueObject.members`, `Policy.aggregate` are real
divergences) — that generator is untouched by either pass.

## `has_many` / `has_one` / `belongs_to` — ported, and what porting them found

README's unported-vocabulary note is closed for three of its four words. `subscribe`
stayed out on purpose — it belongs to `.hecksagon`, a sibling artifact this arc has
never covered, and porting it would reopen that scope decision rather than extend
this one.

**Ruby**: `AggregateBuilder#has_many/has_one/belongs_to`, all sugar over
`reference_to` — same `Reference<Target>` attribute, differing only in the DEFAULT
name (no `_id` mint, and `has_many`'s target is the singular of what was written).
`has_many` deliberately matches Rust's EXISTING shape — a single reference, not a
list. `list_of(Reference<X>)` has no precedent anywhere in this IR (`list_of` is
checked everywhere as a list of value objects — `bin/ir_structs`, `ir_json`, both
dispatchers), so a real one-to-many is a separate arc, not a rename of what already
parses. `Naming.singularize` is new too, mirrored exactly by Rust's (moved from
`parser.rs` into `naming.rs`, public now).

**`syntax.bluebook`** grew three `Keyword` rows and six `Argument` rows in the
Aggregate context — the same shape `reference_to`'s own rows already had, since the
underlying attribute a judge reads is identical regardless of which word declared it.

**Two real, previously-latent Rust bugs surfaced by porting, not by inspection** —
both zero-tested until this session, both caught by hand-probing a bluebook where
`bin/ir` (Ruby) and `--dump` (Rust) diverged:

1. **`absorb_held` built TWO attributes per `has_one`/`belongs_to`.** It pushed a
   `Reference<Target>` into one vector and, guarded by "unless already present," a
   BARE `Target`-typed one of the same name into a different vector — and the guard
   could never fire, because the two vectors were only concatenated at the very end
   of `parse_aggregate`. Fixed by deleting the second push ; `rust/tests/has_relationship_test.rs`
   pins it (reverted-and-confirmed-failing during this session, then restored).
2. **Every aggregate's attributes were secretly reordered.** `parse_aggregate`
   collected `reference_to`/`has_many`/`has_one`/`belongs_to` into a SEPARATE vector,
   PREPENDED at the end, on a comment claiming "the IR has always listed every
   reference before every declared field." Ruby proved the claim false, not merely
   stale — `attribute :id` then `reference_to X` then `attribute :label` comes back
   `[:id, :target_id, :label]`, true declaration order, not references-first. Every
   real aggregate in the corpus happens to write its references immediately after
   `identified_by`, before any plain `attribute`, so declaration order and
   "references first" were the same order every time and nothing told them apart.
   Fixed by removing the separate vector entirely — `reference_to` and its three new
   siblings now push straight into `agg.attributes`, matching Ruby's single
   `AttributeCollector` array exactly. Pinned in `has_relationship_test.rs`.

Both fixes were probed by hand before being trusted : a scratch bluebook exercising
all three words, `bin/ir` vs `rust/target/release/hecksagain --dump`, canonicalised
and diffed — SPLIT before either fix, byte-identical after. **Rebuild the CLI binary
before trusting `--dump`** — mid-session, a stale binary from an earlier
bug-reintroduction probe gave a false SPLIT that had nothing to do with the code.

Gates after both fixes: `bundle exec rspec` 741/0 (up from 733 — three new `dsl_spec`
examples, four `naming_spec` cases, a golden Bluebook.json rewrite for the two new
syntax rows, and a `dsl_coverage_spec` allowlist update), `cargo test --release
--workspace` clean (five new tests in `has_relationship_test.rs`, four in
`naming.rs`), `bin/parity` AGREED across the whole corpus — the ordering fix touches
every aggregate that has ever declared a reference, so the corpus-wide run is what
actually matters here, not the new fixture alone.

## `parser.rs`/`parse_blocks.rs` — reconciled

The ~35 hardcoded keyword checks are done. Every one now maps to a word
`syntax.bluebook` declares, a documented out-of-scope reading, or plain string-parsing
mechanics (comment-stripping, `&&`/`||` continuation joins, literal decoding) — no
ghost words, no fake keyword arguments, no branch that swallows a construct silently.

**Most of the ~35 were not undeclared vocabulary — they were DEAD CODE**, traced to a
single commit (`dfa1a11`, "bring the Hecks rust parser over whole") and never touched
since. Two whole subsystems, deleted (~430 net lines):

- **`rule "Name" do requires { … } end`** — parsed at Aggregate/ValueObject/Entity
  level, panicked if the body wasn't a single expression, and **built nothing into
  the IR even when well-formed**. No `rule` method exists on any builder in this
  project or in Hecks. Zero corpus usage.
- **Shorthand syntax** — bare `String name` instead of `attribute :name, String`, and
  a PascalCase-name-implies-command heuristic (`is_shorthand_command`). Its own type
  table listed `Boolean`/`JSON`/`Date`/`DateTime` — not real primitives ; the
  language's own `Vocabulary::Primitive` admits five, and none of those four. Its
  keyword-exclusion list carried `vow`/`fixture`/`category`, matching no real word
  anywhere. Zero corpus usage, no Ruby equivalent. `reference_to`'s parenthetical
  form (`reference_to(Customer)`) rode on this same apparatus, along with an invented
  `.as(...)` chained-call form and a `role:` kwarg matching nothing in either
  builder's real signature — all removed together. `set` inside a `ProcessManager`
  handler body (`is_set_start`) was the same story, smaller: joined across lines,
  never acted on, no Ruby method, zero corpus usage.

**One real, narrow bug, found and fixed**: `parse_command` accepted `description` as
a silent synonym for `goal`. Neither `hecksagain`'s nor Hecks's `CommandBuilder` has a
`description` method — Rust was quietly more permissive than Ruby, the exact
asymmetry `bin/parity`'s own README names as "the failure most worth catching."
Removed ; only `goal` is recognized now, matching Ruby exactly.

**One real, narrow gap, found and fixed**: `Command#reference_to`'s `optional:`
argument — declared in `syntax.bluebook` (added during the vocabulary-port session,
real on `CommandBuilder#reference_to(type, as: nil, optional: false)`) — was never
actually read by Rust. `reference_attribute` always built `optional: false`
regardless of what the line said. Zero corpus usage, so nothing caught it until this
pass cross-referenced the declaration against what Rust does. Fixed by threading
`optional` through `reference_attribute` (real only for `Command#reference_to` ;
every other caller — an aggregate's own `reference_to`, `has_many`/`has_one`/
`belongs_to` — passes `false`, since Ruby never lets them take it either).

**`from_event`/`from_pm`/`from_iter` — deleted, not merely left alone.** Documented,
which is why the first pass didn't touch them ; asked to look again, and the
documentation turned out to be the last thing standing. Traced end to end
(`dispatcher.rs::deliver_saga_dispatch`, the ACTUAL runtime path — not the parser) :
Ruby's `dispatch_args` resolves a bare `:symbol` binding event-payload-first, then
process-manager memory, with no syntax distinguishing the two ; Rust's real
dispatcher does the identical thing, byte for byte, off the same colon-prefixed
text. `from_event(...)`/`from_pm(...)`/`from_iter(...)` explicit sentinel syntax
was Rust's OWN richer parse of the same binding value — no Ruby method by any of
those three names exists in this project or in Hecks, zero corpus usage, and worse,
BROKEN if anyone had used it : `bin/ir_rust`'s own domain generator never built one
(its comment says so — "ALWAYS A LITERAL, and the colon stays on"), and the wire
flattening (`ir_json::value_spec_text`) dropped the leading colon for
`FromEvent`/`FromPm` while `Literal` kept it, so the explicit form would have
silently round-tripped into being read as a plain string instead of an event/memory
lookup. `ValueSpec` is gone ; `DispatchSpec.with_spec` is `Vec<(String, String)>`,
matching what the language actually declares `Binding` to be. `bin/ir_rust` and
`bin/ir_structs` updated and regenerated (`projected/banking.rs`, `projected/wire.rs`
— the only two chapters that use `with_spec` at all). Gates: rspec 744/0, cargo
clean, every non-Postgres `bin/parity` stage AGREED (Postgres itself was flaky on
clean `HEAD` too — a shared local instance, unrelated to this).

Every deletion and fix is pinned : `rust/tests/command_reference_optional_test.rs`
(the `optional:` fix, reverted-and-confirmed-failing then restored, same discipline
as the vocabulary-port session) ; the full suite run at whole-corpus scope
(`bin/parity` AGREED, 120 mutants) since removing dead branches touches every
aggregate that could theoretically have hit them, not just a fixture.

Gates: `bundle exec rspec` 741/0 (unchanged — nothing Ruby-side moved), `cargo test
--release --workspace` clean, zero warnings (down ~430 net lines with no new dead
code left behind), `bin/parity` AGREED.

**What's next**: `.hecksagon`'s `subscribe` and the sibling-artifact surface remain
out of scope, as decided when `syntax.bluebook` was first scoped to `.bluebook` only.
With the vocabulary gap and the dead-code gap both closed, the case for actually
GENERATING the parser from `syntax.bluebook` — rather than hand-writing it and
checking it — is real rather than aspirational. That is the next rung, not this one.

**Scope that was deliberately left out**, and it is named rather than half-done: only
the `.bluebook` surface is declared. `.port`, `.adapter`, `.hecksagon`, `.world` and
`translations/*.bluebook` are sibling artifacts with their own builders and their own
files; the conformance spec excludes each by name with its reason.

Bluebook first, and it is not optional — `bluebook.bluebook` is where this goes.

## The parser itself, being projected — word recognition, done; arguments, not yet

The actual goal named at the top of this file: not shapes, the PARSER. Six commits
(`b8771c1`, `fc52cff`, `2d7294f`, `83c492a`, `5a755d0`, `874a8fe`), one context each,
same discipline every time — generate the WORD-TO-CATEGORY table from
`Syntax::Keyword` (rows where `opens` is not empty), swap a hand-written literal
check for a lookup against it, leave what happens once a category opens completely
hand-written. `bin/ir_dispatch_words` → `rust/src/bluebook/ir_dispatch_words.rs`,
held equal by `spec/ir_dispatch_words_export_spec.rb`.

**Bluebook** (4 words, `dispatch_block`) was the easy case — already its own small,
uniformly-checked function. **Aggregate** (5 words) and **Entity** (2 words) needed
disentangling recognition from argument-filling within one bigger loop, and along the
way found three words checked with a bare `starts_with(literal)` — no word-boundary
guard at all — normalized to the shared `keyword_matches` (verified safe: nothing else
in the corpus shares any of these words as a prefix, checked by hand before trusting
the tightening). **ProcessManager** (1 word) and **Handler** (1 word) each had their
own hand-rolled boundary check (`starts_with("on ") || starts_with("on\t")`;
`starts_with("dispatch ") || starts_with("dispatch\t") || starts_with("dispatch\"")`)
replaced by the same generated lookup. **OneOf** (1 word, `member`) is the one case
where the code never branches on the generated category at all — Rust has no separate
`Member` struct to branch to (pairs live inline on the owning `ValueObject`) — so only
the recognition moved, not a dispatch decision.

**That is every context `Syntax::Keyword` declares an opens-bearing word for.** Command,
Query, Policy, ReadModel, ValueObject, and Type have none — every word in those
contexts fills a field rather than opening a nested category, which is a different
generation problem (see below), not a missed context.

Verified the same way every time, and it is worth naming why it could be : each slice
is a **zero (or near-zero) behavior-change refactor** — the words recognized and the
functions called do not differ, only where the word list lives and (for the boundary-
check normalizations) whether a theoretical false-positive prefix match is now caught.
That means the FULL existing suite is free, complete verification with nothing new to
write beyond the export-equality spec : `bundle exec rspec` (754, 0 failures across all
six), `cargo test --release --workspace` (clean, zero warnings, all six), `bin/parity`
AGREED end to end on every run that didn't hit unrelated Postgres noise (a concurrent
session's own `bin/parity` runs collided on shared `/tmp/parity.output.*` paths and on
the local Postgres instance itself — RESTART's own named trap about stale temp files,
now observed from the OTHER side. A rerun always came back clean; the actual
comparisons that DID print during the noisy runs — "runtimes agree", "histories
agree" — passed regardless).

**The next rung is materially harder and was scoped out of every one of these six
commits on purpose : ARGUMENT generation.** Turning a declared `kind`
(`text`/`symbol`/`constant`/`flag`/`literal`/`pairs`/`list`/`number`) into actual
parsing code, per word, per context. Unlike word recognition — where a wrong
generated table just fails to recognize something, loudly, the same way a stale
hand-written list would — a wrong ARGUMENT generator can produce a parser that reads
a value WRONG rather than not at all, which is a categorically worse failure mode (the
encoding-loss family this whole codebase keeps finding, now with a generator able to
manufacture a new instance of it). Do not attempt this by cloning the word-recognition
pattern at a larger scope. It needs its own design pass : which `kind`s are simple
enough to generate a real reader for (`flag` — a bare true/false — is probably the
smallest possible next slice), which need to stay hand-written a while longer
(`pairs` already has per-word variation — `then_set`'s `append:` vs `on`'s
`transition:` bind their pairs to completely different fields), and a verification
discipline that catches a WRONG reading, not just a MISSING one (the corpus alone is
not enough — see "both runtimes can be wrong identically" below ; a generator and a
hand-written parser reading the same wrong thing would agree with each other and
still be wrong).

## WHAT THE PROJECTION IS ACTUALLY WORTH (do not oversell it)

This was interrogated hard at the end of the last session and the honest answer is
smaller than the commit messages suggest. Carry the honest version:

- `bin/ir_structs` (10 structs) + `bin/ir_vocabulary` (2 enums) generate ~300 of
  ~8000 Rust lines. **`bin/parity` already caught shape drift** — Ruby's `to_h` vs
  Rust's `--dump` splits when the language gains a field Rust lacks. All ten projected
  structs are exercised by banking, so for everything it covers, parity had it.
- It did NOT enable `bin/ir_rust` either — the domain projection needs the struct
  DEFINITIONS to exist, not to be generated.
- What survives: one narrow gap (parity only sees what the corpus reaches; a field on
  a category the corpus never exercises — the language's own `Member`, `Handler`,
  `Dispatch` — never reaches it), one fewer hand-maintained artifact, and the
  generator's exclusion header as a measured map of where "the spec is the system"
  is not true yet.
- **The value is in writing the generator, not running it**: you cannot emit a field
  the language does not declare, so building one forces a field-by-field audit.
- It is only worth its weight if the ladder continues. Shapes were never where the
  money was.

## The projection as it stands

    bin/ir_structs     language -> 10 Rust struct declarations   (rust/src/bluebook/ir_structs.rs)
    bin/ir_vocabulary  Vocabulary -> 2 Rust enums                (rust/src/bluebook/ir_vocabulary.rs)
    bin/ir_rust <bluebook>  a DOMAIN -> Rust values              (rust/src/bluebook/projected/*.rs)

Eight chapters compile in: Banking, Expression, Market, Pizzas, Reflex, Relay, TillRoom,
Wire. **Reflex's exclusion is CLOSED** (a session concurrent with this one — see
`spec/ir_rust_export_spec.rb`'s own updated comment) : `Query`/`ReadModel` grew the
eight specification options, so there is somewhere to project them to now.

- `Runtime::boot` prefers a projection over parsing; `Runtime::boot_projected(chapter)`
  boots with NO file at all. `bin/parity` runs the whole corpus with Rust booting from
  projections.
- **A projection is SEALED to its source** by SHA (`SOURCE_SHA` in each projected file,
  checked by `projected::by_source`). Name-only lookup hijacked any same-named chapter
  — a router test's own `Banking` fixture got the real banking — and kept answering
  after its source was edited. Do not weaken that seal.
- `bin/ir_rust` takes a BLUEBOOK, not a domain directory. Booting mints an era into the
  tree it reads, so a directory-taking generator could not be run twice.
- Two checks: `spec/ir_rust_export_spec.rb` holds each file equal to the generator
  (determinism); `bluebook::projected::tests` flattens the projected domain back through
  `ir_json::domain_to_value` and diffs it against `spec/golden/ir/*.json`, which is
  Ruby's own frozen `to_h` (correctness). **The second is the one that matters** — it
  found three inversion bugs the moment six more chapters were projected.

## The typed seam (item 2, partly done)

`Runtime` now holds the typed `Domain`; `ir: Value` is derived from it in `new`. Only
the identity reader has moved over (`identity::of_paths`, via `declared_identity`).
**~195 `.get("…")` reads remain** across `dispatcher.rs` and `mutations.rs`. Converting
them blind would leave TWO sources of truth — the seam exists so they move one at a
time. Caveat: `resolve_admitted_sets` annotates the JSON AFTER derivation, so `ir` is
derived-then-annotated, not a pure projection.

## Coverage gates — all three allowlists are EMPTY, keep them that way

    spec/plurality_coverage_spec.rb     every declared list filled with >1 somewhere
    spec/optionality_coverage_spec.rb   every nullable wire field filled somewhere
    spec/combination_coverage_spec.rb   all 78 pairs of 13 forms met on one aggregate

Each fails in BOTH directions — an excuse the corpus has outgrown fails too. Adding a
property to the combination gate makes it name its own uncovered pairs immediately.

**These found five things no test went red for**: `emits` never announcing twice,
`entities` never choosing, `version` parsed by both runtimes and declared by neither,
`Dispatch.with_spec`'s three-copy translation table, and a Ruby/Rust attribute-order
divergence. THREE were found by a field being UNMEASURABLE — which is why making the
gates fail on that rather than skip is load-bearing.

## Corpus members added for coverage (not examples)

`spec/parity/domains/` is a third corpus category — domains that exist ONLY to hold the
two runtimes to a shape no example declares.

- **market** — composite identity (`row.value` + `number.value`), two entities shaped
  differently (Booking joined from two paths, Inspection from one), a two-event command,
  a cross-reference, a closed set, a default, an optional argument. Runs through Heki
  AND SQLite.
- **relay** — one `Raise` announces TWO events with a policy on each, and the second
  acts on what the first creates, so ORDER decides the outcome. Two read models, two
  procedures over one stream.

## Traps that cost real time in the last session

- **`bin/parity` output is LONG and the interesting lines are at the TOP.** `tail` is
  the wrong tool; it truncated the corpus list three separate times.
- **Run the suite BEFORE `GOLDEN=rewrite`.** Regenerating first launders a regression
  into a fixture. A `with_spec` rename emptied every saga binding and the goldens
  absorbed it — caught only because the diff was UNBALANCED (81 and 66 lines of net
  deletion where a rename should be even).
- **`bin/ir` mints an era.** Iterating on a corpus bluebook leaves `data/eras/` and the
  next run refuses with shape drift. `rm -rf <domain>/data` between runs.
- **`cargo build` is not enough** — `cfg(test)` code fails separately. Run `cargo test`.
- **The shell cwd drifts into `rust/`** after any `cd rust`. Use absolute paths.
- **Assert every anchor BEFORE writing anything** in a multi-file script. A field-order
  mismatch caught one halfway and nothing was half-applied.
- **Adding an aggregate needs a `persisted_by` bind** in the `.hecksagon`, or boot
  refuses. Parsers agreeing is not the domain running.

## Named gaps — do not quietly close these by picking a runtime

- **wasm: this runtime cannot target it at all.** `fs` and rusqlite are unconditional.
  `~/Projects/hecks` ships to wasm (cfg-gated deps + a Cloudflare R2 adapter); we do
  not. Its own arc. See the `project-hecks-gap` memory.
- **`correlates_by` on a value-object argument diverges** — Ruby keys the conversation
  on the whole object, Rust on its JSON text. Neither is a scalar, and "an id is a
  scalar" is the rule the identity arc established. What a correlation key may BE is a
  language question. Recorded in `relay.bluebook`; relay correlates on the root instead.
- **`boot_projected` attaches no adapters** — hecks takes wiring as values too.
- **Reflex's exclusion — CLOSED**, concurrent with this session: `Query`/`ReadModel`
  grew the eight specification options, so Reflex now projects like every other
  chapter. Left here so the entry isn't silently wrong ; not this session's work.
- **Minting stays Ruby-only** until `bin/parity` can mint from BOTH runtimes and diff.

## Standing rules that still hold

1. **Never modify `~/Projects/hecks`** — reading it is fine and was useful; changing it
   is not.
2. **Ruby wins when the shapes differ.** The exporter converts.
3. **Zero warnings, zero failing tests.** Tests do no IO except `spec/adapters/`.
4. **Bluebook first.** If it is about bluebooks, `bluebook.bluebook` is where it goes.
5. **Don't trust green, and don't trust a filename.** Every real defect this session was
   found by measuring a diff or probing by hand — never by the suite going red.

---

# Findings worth not rediscovering

Salvaged from `HANDOVER.md` before it was deleted (it predated the projection work
and its opening claim — "Do not call Rust a projection" — had gone false). These are
the parts that are still true and still expensive to relearn. The full original is in
git history.

## The house failure mode: a defect written down as expected behaviour

Five in one session, each PASSING because the thing asserting it agreed with the bug —
a spec asserting a mutation into a field its fixture never declared; banking crediting
an account with `colour: "red"` and writing the bug into its own narrative; a saga spec
titled "the compensation puts the money back" where the TEST put it back by hand; a
transfer hand-driven into a frozen destination and recorded as settled; a `given` on
`Aggregate.Seal` that was invented for Seal, never dispatched, and not even true.

It recurred in the projection session twice more: `GOLDEN=rewrite` before the suite
absorbed an emptied saga binding as expected output, and two `dsl_spec` cases pinned
`no ValueObject with id "…"` for a category that has no `id`.

**Don't trust green, and don't trust a filename.** Every real defect has been found by
probing by hand or measuring a diff — never by the suite going red.

## Both runtimes can be wrong identically, and parity certifies it

A read model's gathered heads derived their name with `snake(target) + "s"` in BOTH
runtimes, so the meta-domain handed back `querys`, `entitys`, `policys` — green on
every one. `bin/parity` can only prove Ruby and Rust AGREE; it can never catch a bug
they share, because there is no third oracle. That gap is not closable by more corpus
or more fuzzing — it is what the hand-written-Go-then-specialize ratchet is for.

## Encoding losses are the largest family of bug in this codebase

Every one has the same shape: reading an OBJECT where the IR's `to_h` holds the
SPELLING. `order_by`/`limit` stored as `"#<struct LimitSpec value=3>"` because
`Array(an_object)` WRAPS rather than destructures; a where-clause value losing the
colon that tells `":ceiling"` the argument from `"ceiling"` the string; an append's
bindings stored raw so a literal was indistinguishable from an argument; a default and
a literal mutation source through `to_s`. **When in doubt, offer what `to_h` spells.**

The projection session added three more of exactly this family, all in `bin/ir_rust`'s
inversions: a literal-object mutation source rendered as Ruby `inspect` where Rust
reads the bluebook spelling; an object literal in an append binding read as an argument
NAMED `{:value=>"credit"}`; and `:source` projected as `FromEvent`, which renders bare,
when a plain `:source` is a `Literal` that KEEPS its colon.

## Not all order matters

BEHAVIOUR-BEARING order must survive: mutations apply in sequence, a lifecycle takes the
FIRST matching transition, a compensation credits before it reverses. PRESENTATION order
need not: nothing looks a command up by position. "Index for index" is a property of the
COMPARISON, not of the IR.

## Ask whether a rule is unsayable or just badly modelled

The reference-shape rule looked like a sublanguage gap (`start_with?` unavailable). It
was a STRING where a reference belonged. `reference_to Aggregate, as: :points_at` is
stronger than a prefix match, because a prefix match only checks the text looks right.

## An argument with nowhere to land does not persist

Bit twice in one day. `disputed_by` was accepted, resolved, gated the command — and
vanished, because the aggregate had no field for it. Then `Command.Declare` took
`entity_id`, dispatched it correctly, and every entity command came back unowned,
because the Command AGGREGATE had no `entity_id` either. **A command argument and the
field it writes into are two declarations; having one is not having the other.**

## Vocabulary that is still pattern names, not words a bank says

`ProcessManager`, `Handler`, `Dispatch`, and the `lifecycle`/`saga` vocabulary. The
collapse they hide: a procedure is an aggregate advanced by EVENTS instead of commands,
`correlates_by` is a `reference_to`, and a status is an attribute whose values are a
closed set with declared moves. An arc, not a rename.

## The unwind is COARSE and the corpus cannot tell

`on :refused` is ONE compensation for a whole procedure; banking hand-lists two undos in
the right order, and the runtime does not know which legs completed. Right for two prior
steps, wrong for four. Discriminating case: three undoable steps where only the first
two complete.

## Smaller ones

- **A refusal is not an event.** `on :refused` is the compensating leg's trigger, bound
  to `IR::ProcessManager::REFUSED`.
- **Procedure and saga are different things.** A procedure coordinates; it is a saga when
  it also undoes. `IR::Saga` is a READING of the source, deliberately not in `to_h`, and
  `saga` appears in no `.bluebook`.
- **`grep saga` matches "heckSAGAin".** Use `\bsagas?\b`.
- **Hand-probes dirty `examples/*/data/`.** `git checkout -- examples/` after any script
  that boots a real domain.
- **`bin/parity` cleans up its temp dirs** — `/tmp/parity.*.json` files are STALE. Read
  `bin/parity`'s own output or drive the domain live.
