# Restart prompt — hecksagain (and one open thread in Hecks)

Paste this into a fresh session.

---

We are building **hecksagain** at `~/Projects/hecksagain` — Hecks rewritten with
Ruby as the source of truth. Read `README.md` first, then this.

## The thesis

In Hecks the parser is authored twice (Ruby DSL + Rust parser) and kept in step
by a parity suite. Every drift retired there was a disagreement between those
two authors. Here, **Ruby holds the semantics and Rust is a projection, except
the interpreter**. The arrow only ever runs `Ruby → IR → Rust`. Never generate
Ruby from IR.

## Standing rules — these are not negotiable

1. **Never modify `~/Projects/hecks` unless asked.** Read from it, copy out of
   it. Verify with `git diff --name-only HEAD -- rust ruby examples`.
2. **Don't hand-write what Hecks already has.** Cherry-pick the file whole and
   unedited. But see "simplifying is not copying" below — the one way this rule
   bit back.
3. **The DSL constructs the Ruby classes.** `aggregate "Pizza"` builds a real
   class as it reads ; `command` defines a real method. `Pizza.create_pizza(...)`
   is the public surface. `dispatch` is private plumbing.
4. **Zero warnings, zero failing tests.**
5. **Tests do no IO** except `spec/adapters/` — the domain runs in memory.
6. **Ruby wins when the shapes differ.** If the interpreter wants a different
   shape, the EXPORTER converts. Never change how a bluebook is written to suit
   a projection — that is the inversion this project exists to avoid.

## Current state (hecksagain @ baade06, all green)

```
bundle exec rspec                                189 examples, 0 failures
cd projection/rust && cargo test --release --workspace   128 passed, 0 warnings
bin/parity                                       banking, pizzas, grammar — all stages
```

## Layout

Ruby is the source ; everything under `projection/` is projected from it. The
folder says the thesis out loud, and leaves room for `projection/go/` beside
`projection/rust/`.

```
lib/hecksagain/                  projection/rust/src/
  bluebook/dsl/                    bluebook/parser.rs      (ruby BUILDS via DSL,
  bluebook/ir/                     bluebook/ir.rs           rust BUILDS via parser)
  bluebook/expression/             bluebook/expression/    file-for-file
  runtime/                         runtime/
  projector/                       projector/ir_json.rs    THE ONE SEAM

  ports/<name>/<name>.port         ports/<name>/           contract + resolution
           <name>.rb
  adapters/driven/<name>/          adapters/driven/<name>/
           <name>.adapter                                  sqlite is its own crate
           <name>.rb                                       (a port may not depend
  adapters/driving/  — empty        on an adapter ; Cargo enforces it)

  grammar/expression.bluebook      the sublanguage a predicate may be
examples/{pizzas,banking}/
spec/parity/*.json                 one script per domain
```

An adapter never lives INSIDE its port : the adapter declares the port and the
port never names its adapters. Three persistence adapters exist — Memory,
Sqlite, Heki — and all three are in-process, because persistence is the one
impure edge with a bounded lifecycle (hydrate before the sync core, persist
after it returns). Every other port would run out-of-process.

`bin/parity` walks the corpus : parsers agree on the IR → runtimes agree on
behaviour → stores agree. Stage three ASKS THROUGH THE PORT (`bin/stores` boots
the domain and calls `count`) so nothing in the harness knows what a `.heki` is.

## THE OPEN THREAD — finish this first (in Hecks, not hecksagain)

Three fixes were in flight in `~/Projects/hecks` when the session ended. Chris
asked for them explicitly, so the never-modify-Hecks rule is suspended for this
work. **Nothing is committed. The tree is dirty.**

### What is already done and verified

`%w[a b c].include?(value)` — the corpus's way of saying "one of these", used by
**58 invariants across 14 bluebooks** — could not fire. There was no list
literal, so the receiver resolved to nothing, `.include?` fell to its false arm,
and the payload gate skipped the clause as unjudgeable. Every one looked exactly
like a rule.

Fixed by teaching the LANGUAGE the construct rather than rewriting 45 distinct
predicates into `||` chains (which would bend 14 bluebooks to fit the
interpreter) :

- `rust/src/runtime/interp_expr.rs` — `%w[…]` is a list literal
- `rust/src/runtime/interp_givens.rs` — `.include?` resolves a LITERAL receiver
  (field receivers untouched) ; `String#include?` is SUBSTRING as in Ruby, not
  the CSV-membership reading it had
- `rust/src/runtime/payload_gate_terms.rs` — `judgeable` admits literal-set
  membership

8 unit tests in `interp_givens.rs` pass, covering membership, near-miss,
substring, and the list-field arm that was already correct.

### What is NOT working

**A live dispatch still accepts a value outside the set.** The interpreter judges
it correctly in isolation, so the payload gate is not reaching that invariant.
Cause not found. Reproduce :

```sh
cd ~/Projects/hecks
rust/target/release/storehouse /tmp/wprobe/wprobe.bluebook \
  WProbe::Probe.SetMode mode=banana     # should refuse ; currently accepted
```

(`/tmp/wprobe/wprobe.bluebook` may need recreating — an aggregate with a
single-attribute VO whose invariant is `%w[ensure status stop].include?(value)`.)

### The three fixes in progress (steps 1 and 2 written, step 3 unrun)

Hecks's canonical IR omits VO invariant EXPRESSIONS, carrying only names. The
stated reason — "the Ruby side holds the predicate as a Proc (source
unrecoverable)" — was true when written and is untrue since Ruby 3.3 shipped
Prism. The cost : **an invariant can be inverted while keeping its name and the
parity contract sees no change.** Two runtimes then enforce different rules and
agree perfectly about it.

1. **DONE** — `ruby/hecks/bluebook_model/predicate_source.rb` (new, untracked) :
   Prism recovery of a block's body. `ruby/hecks/dsl/value_object_builder.rb`
   passes `expression:` when building an invariant.
2. **DONE** — `parity/canonical_ir.rb` and `rust/src/dump.rs` both emit the
   expression.
3. **NOT RUN** — parity. This is where drift will surface : Ruby's Prism
   extraction and Rust's parser capture must produce the SAME text. Rust joins a
   multi-line VO invariant body with `" && "` ; `PredicateSource.canonicalise`
   mirrors that. Unverified.

**The immediate next step is wiring the require** — `PredicateSource` is not
autoloaded yet. `ruby/hecks/bluebook_model/structure.rb:50` shows the autoload
style. Then run :

```sh
cd ~/Projects/hecks
ruby -Iruby parity/parity_test.rb
cd rust && cargo test --release --workspace
```

Expect drift on the first run. `parity/known_drift.txt` is currently EMPTY (full
parity) — keep it that way rather than adding entries.

### Committing in Hecks needs an override

The pre-commit loc-ratchet is BRANCH-scoped and blocks every commit on
`feat/cask-runtime-files`, including pure-markdown ones — the `+2816` delta is
the in-flight cask-runtime work, not yours. Chris authorises
`[loc-ratchet-override: <concrete reason>]` per commit. **Never self-authorise ;
let the hook block, report it verbatim, and ask.**

## Findings recorded but NOT fixed

- **`judgeable` fails open by design**, delegating to "the Ruby runtime, where
  invariants are live Procs". `CLAUDE.md` says Rust is the only runtime. The
  second enforcer named in that comment is not running. Decision needed, not
  just a code change.
- **Multi-field VO coercion in Hecks** — `payload_gate` validates single-field
  wrapper VOs only (explicitly Phase 1) ; multi-field VOs are skipped entirely.
  Grep the corpus before deciding whether it matters.
- **hecksagain : Rust resolves ONE persistence bind per domain**, Ruby resolves
  per aggregate. A domain mixing adapters would silently bind everything to
  whichever Rust saw first. Banking is uniformly Heki, which avoids it.
- **hecksagain : adapters disagree about `events`** — Ruby's sqlite writes an
  events table, Rust's does not. Excluded from stage three with that reason
  stated.
- **No gate fails when a new DSL keyword has no parity exercise.**
  `dsl_coverage_spec` catches a method with no UNIT test, not one with no CORPUS
  test. ~20 lines : cross-reference the DSL method list against keywords
  appearing in `examples/`.

## Findings worth not rediscovering

- **Agreement is not correctness.** Parity proves the two sides read the same
  document ; it says nothing about whether either is right. Six of today's
  defects were live in BOTH runtimes simultaneously, which parity structurally
  cannot detect. The chain that works : `dsl_spec` pins Ruby is RIGHT → parity
  pins Rust EQUALS Ruby → the corpus pins it covers EVERYTHING.
- **A rule that always passes is indistinguishable from a rule that holds.**
  Today's recurring shape. `!value.empty?` never fired in 20+ Hecks rules ;
  `%w[]` membership never fired in 58 ; two invariants in hecksagain's own
  grammar chapter raised evaluation errors instead of enforcing. Every one
  looked green.
- **Simplifying is not copying.** hecksagain's `creates?` bug was a REGRESSION
  introduced by simplifying Hecks's rule to `references.nil?` on the way over.
  Hecks compares the reference target against the AGGREGATE name and is correct.
  The simplification looked equivalent and was not.
- **The corpus is the guarantee.** Writing banking — a domain exercising every
  DSL word — found four real drifts on its first run. Adding the grammar chapter
  found two more. None were reachable from pizzas.
- **Exercise constructs for real.** Parity over `null` matching `null` proves
  nothing. Every keyword must appear in a domain doing something.
- **Hecks's specializer no longer exists.** Bulk-retired 2026-06-27 ; the golden
  harness went 40 tests → 1. No `storehouse specialize`, no goldens, nothing
  emits Rust. Reviving it is new construction. The retirement note — "a
  .bluebook whose only job is to re-emit imperative Rust captures no domain" —
  is correct about what was built, and does NOT condemn the rule-declaring
  approach `extraction.bluebook` conceives.
- **`FileTool.Write` corrupts JSON content** through the storehouse door — it
  parsed a JSON string as structured data and wrote `{3 fields}`. Write JSON via
  a Ruby one-liner instead.
- **BSD `sed` has no `\b`**, and `perl -0pi` on a whole file will happily
  prepend to line 1 if the pattern misses. Prefer surgical `FileTool.Edit`.
- **`cargo build` in a workspace with a root package builds only that package.**
  Use `--workspace`.
- **Prism needs a real file.** A bluebook `eval`'d from a string has no source,
  so every predicate extracts empty.
- **`spec/dsl_coverage_spec.rb` fails when a DSL method has no test.** That is
  deliberate — it caught three additions today. Add the example, then declare it.

## One thing to watch

The DSL is now 685 code lines across 12 builder files, of which roughly 30 are
mechanism (`instance_eval`, class construction, the const shim) and the rest is
accumulation the grammar already describes. A collapse to one interpreter + a
keyword table was designed and deliberately deferred — collapsing while still
adding keywords gets you a half-collapse worse than either end state. Revisit
once the language stops growing.
