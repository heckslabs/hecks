# The Bluebook grammar

Clause-numbered G1..G13, cross-referenced to `docs/semantics/bluebook-semantics.md`'s
C-clauses where the two touch. Where `bluebook-semantics.md` says what a
declaration *means*, this document says what text is *admitted* as one
in the first place — the missing half stage 11 of the migration plan
(see the plan artifact's own §11 addendum) named: "the grammar itself…
until a grammar spec exists, 'the base language' is whatever the Ruby
builders accept."

## G1 — Scope: two grammars, one already formal

A `.bluebook` file has two layers, and only one of them lacked a formal
grammar before this document:

- **The construct/keyword surface** — `aggregate`, `command`,
  `attribute`, `sets`, `emits`, `given`, and every other word a
  `.bluebook` may open a block with, plus the exact arguments each
  admits — is **already** declared as data, not prose: the language's
  own self-hosted `Syntax` aggregate
  (`lib/hecks/language/bluebook/syntax.bluebook`) enumerates every
  keyword and argument as real `Keyword`/`Argument` rows, dispatched
  into a live domain instance at boot
  (`Hecks::Bluebook::MetaValidator::SyntaxBoot`) the same way any other
  domain's own commands are. `bin/reference` regenerates
  `docs/implemented/reference/*.md` — one page per construct — **from
  that table**, gated so a word with no prose or no runnable example
  fails the build. `spec/syntax_conformance_spec.rb` holds the DSL
  builders to it in both directions; `spec/parser_parity_spec.rb` holds
  `hecks-parse`'s own construct-level output byte-identical to Ruby's
  own exported IR, over the real corpus. **This document does not
  restate that table** — `docs/implemented/reference/index.md` is its
  authoritative, generated, coverage-gated form. `hecks-parse`'s own
  `rust/parser/src/keywords.rs` is itself generated from the same table
  (`bin/project_keywords`-class projector), so drift between the two
  engines' construct grammars is a build-time impossibility, not
  something this document could add value pinning again.

- **The expression grammar** — what `given("…") { … }`,
  `ensures`, `invariant`, `precondition`, and a policy's `where` may
  hold inside the block — is declared **nowhere as data**. It exists
  only as an ordered sequence of pattern-matches inside
  `Hecks::Bluebook::Expression::{Evaluator,Resolver}#parse`
  (`lib/hecks/bluebook/expression/{evaluator,resolver}.rb`), hand-mirrored
  in `rust/parser/src/expr/{evaluator,resolver}.rs`. Nothing before this
  document named the fixed order those patterns are tried in as a
  *grammar*, and nothing held the two hand-written copies to it except
  eyeballed review. **G2 through G11 are that grammar.** G12 covers the
  one declared sub-grammar within it (`pattern:` strings, already
  formal). G13 states the accept corpus this document is backed by and
  the contract it enforces.

## G2 — Lexical basics

An expression is Ruby-like surface syntax over a small, fixed value
domain (C3.1). The productions below are tried by the ENGINE in a FIXED
ORDER — the first one whose shape matches wins, and nothing about
these productions requires understanding Ruby itself, only these
specific string shapes:

| Literal | Shape | AST leaf |
|---|---|---|
| Integer | `-?\d+`, no decimal point | `int` |
| Float | `-?\d*\.\d+` | `float` |
| String | wrapped in a single matching pair of `"…"` or `'…'` (`quoted?`) | `str`, quotes stripped |
| Boolean | the bare words `true` / `false` | `bool` |
| Nil | the bare word `nil` | `nil` |
| Array | `[`…`]`, comma-separated elements split at bracket/quote-aware top level (nested `[`/`(`, quoted commas, do not split) | `array`, each element re-parsed by this same grammar |
| Lookup | anything else: a bare name or a dotted path (`parent.status`, `old.ledger.size`) | `lookup`, `path` an array of the dot-separated segments |

`old`, `parent`, and a block's own bound parameter (G10) are **not**
special syntax — they are ordinary heads a `lookup` may name; which
names actually resolve to something is a semantics question (C2.2),
not a grammar one. A `Lookup` is also the universal catch-all: G2
through G11 name every OTHER production this grammar recognizes, and
anything matching none of them still parses — as a `Lookup` holding the
whole unrecognized text as its path. **There is currently no shape of
free expression text this grammar refuses outright** (contrast G12,
which does have a real reject boundary) — G5 states this precisely, and
G11 documents where that catch-all currently hides a real gap between
the two engines rather than a shared, intentional design point.

## G3 — Construct surface: see G1

Deferred entirely to `docs/implemented/reference/` — see G1.

## G4 — Boolean and comparison composition, in precedence order

Tried in this exact order, each a full recursive re-entry into this
same grammar for its own operands:

1. **`||`** — split at the first TOP-LEVEL `||` (outside parens/quotes/brackets); `or`, `left`/`right`.
2. **`&&`** — same, for `&&`; `and`, `left`/`right`.
3. **`!`** — a bare leading `!` negates **the entire remainder**, recursively re-parsed; `not`, `expr`. Tried **before** G4.4 and G4.5, not after — `!names.include?(x)` means `!(names.include?(x))`, never "call `.include?` on the negated receiver." This is a fixed point, not an accident: Ruby's own `Evaluator.parse` carries a comment recording exactly this ordering as the fix for a real, live bug (a naive `.include?`-first scan swallows a leading `!` straight into the haystack text, which the leaf grammar then cannot resolve as membership at all). `spec/corpus/grammar/negated_include.json` pins it, on both engines — `hecks-parse` had silently regressed to the pre-fix order until this document's own corpus caught it (see this file's own git history for the fix).
4. **`.include?(…)`** — rightmost `.include?(` to the matching close-paren; `include`, `haystack` (everything before the marker)/`needle` (the argument text), both re-parsed. A literal array on the left (`["a","b"].include?(x)`) is the ordinary G2 array-literal production for the haystack — the OR-chain desugaring `bluebook-semantics.md` describes happens at IR *emission*, one layer above this grammar, never here.
5. **Comparison** — the first of `==`, `!=`, `<`, `<=`, `>`, `>=` found at TOP LEVEL, tried in that declared order (`Vocabulary::Operator`'s own table); `compare`, reduced to the algebraic triple `{less_than, equal, negated}` with `left`/`right` each re-parsed. `nil`, integers, floats, strings and booleans are all legal operands (G6); nothing about the grammar restricts which OPERAND TYPES may flank a comparator — that a comparison between incompatible types is a runtime Fault, not a parse-time refusal, is C8.3/C3.2's business, not this grammar's.

Falling through all five reaches G2's `Lookup` catch-all directly — a bare
name with no recognized operator anywhere is not a boolean production at
all.

## G5 — The catch-all is total, not partial

Stated once, precisely, because it is easy to assume otherwise: **for
free expression text, there is no shape this grammar refuses.** G2's
`Lookup` production accepts literally any string that survives G4
through G10 unclaimed. This is the accidental-not-intentional half of
C2.1's "the op roster is closed… an unknown op is refused" — that
sentence is true of `ast` JSON **loaded from storage or the wire** (a
literal, malformed `{"op": "whatever"}` node is refused at load), but
NOT true of arbitrary human-typed expression text, which this grammar
always accepts as *something*, semantically nonsensical or not. G11's
seven-op gap is a direct consequence: an expression `hecks-parse` fails
to recognize does not error — it silently becomes a `Lookup`, which is
exactly why the accept corpus (G13), not eyeballing, is what catches
the two engines disagreeing about which op a given text means.

## G6 — Literals as leaves

The seven leaf literal kinds (`int`, `float`, `str`, `bool`, `nil`,
`array`, and `lookup` itself as the catch-all leaf) are G2's own table,
restated here as their own clause because every OTHER production in
this grammar (G4, G7, G8, G9, G10) ultimately bottoms out in one of
them as an operand. `spec/corpus/grammar/{integer,float,string,bool}
_literal.json` and `nil_equality.json` pin one of each.

## G7 — Membership

`.include?` is G4.4 — restated here because it is the one production
whose LEFT operand commonly carries a nested literal (G2's array
production) rather than a single lookup, and because C3.2's "structural
equality" is what the `needle`/`haystack` comparison inside `include`
actually uses at evaluation time — a grammar fact (this clause) and a
semantics fact (C3.2) that are easy to conflate. `array_literal_include
.json` pins the array-haystack shape.

## G8 — Arithmetic

- **Addition** — the first TOP-LEVEL `+` (outside parens/quotes/brackets); `add`, `left`/`right`, each re-parsed. The ONLY arithmetic operator this grammar has — no `-`, `*`, `/` production exists at all (an unrecognized use of any of them falls through to `Lookup`, per G5).
- **Modulo** — `.modulo(…)`, a method-call shape rather than an infix operator; `modulo`, `receiver`/`divisor`.

`old.ledger.size` inside an arithmetic operand is not special syntax —
`old` is an ordinary G2 lookup head; C4.6/C7's "candidate vs. pre-state"
reading of what `old` resolves TO is semantics, not grammar.

## G9 — Suffix predicates

A single dotted suffix, tried in this order, each wrapping ONE receiver
(itself fully re-parsed):

1. `.length` / `.size` — the SAME production (`Size`), Ruby's own
   Array/String alias, tried at two different points in the fixed
   order but producing an identical node either way.
2. `.positive?` / `.negative?` / `.zero?` — `sign_test`, reduced to the
   same `{less_than, equal, negated}` triple G4.5 uses for comparisons
   (`.positive?` = `¬(x<0 ∨ x=0)`).
3. `.empty?` — `empty`.
4. `.to_s` — `to_s`.

`length_alias.json`, `size_dot.json`, the three `sign_test_*.json`
fixtures, `empty_predicate.json` and `to_s_suffix.json` each pin one.

## G10 — Collection block forms

A receiver followed by `.all?`, `.any?`, `.none?`, or `find`, then a
brace-delimited block with exactly one bound parameter
(`{ |param| … }`), the block body brace-matched (nested braces inside
the predicate do not end the block early) and re-parsed as its own
full expression with `param` as an available lookup head:

- `.all?` / `.any?` / `.none?` — `block_predicate`, `mode` one of
  `all`/`any`/`none`; admits **nothing** after the closing brace.
- `find` — `find`; additionally admits a **dotted projection path**
  after the closing brace (`seats.find { |s| … }.row.value`), carried
  as `find`'s own `path` — the one place this whole grammar allows a
  production's own trailing suffix to itself be a further dotted
  lookup rather than a fresh top-level re-entry.

`block_predicate_{none,any,all}.json` and `find_with_path.json` pin
each shape, including the trailing-path case.

## G11 — Known gap: seven ops `hecks-parse` does not parse at all

Ruby's own `Resolver.parse` additionally recognizes `MatchesRegex`
(`.match?(/…/…)`), `Presence` (`.presence`), `Split` (`.split(…)`),
`StartsWith`/`EndsWith` (`.starts_with?(…)`/`.ends_with?(…)`), and the
bare collection accessors `First`/`Last` (`.first`/`.last`, distinct
from `find`'s own block form, G10). **`rust/parser/src/expr/resolver.rs`
has no production for any of the seven** — confirmed by reading its own
dispatch table, which stops after G9's suffixes and G10's block openers
— so every one of these falls through to `Lookup` (G5) instead, exactly
the "silently means something else" hazard G5 warns about. This is
recorded here as OPEN, not fixed, matching this whole migration's
discipline for a real, scoped, not-yet-closed gap (see ADR 0037's own
Finding 5/7 for the same pattern applied to runtime behavior rather
than grammar). `matches_regex_gap.json` through `last_gap.json`
(`spec/corpus/grammar/`) are `ruby_only: true` — Ruby's own answer is
frozen and pinned; `hecks-parse`'s answer is not compared, so the gap
stays visible in the corpus without failing the suite for something
this document has already catalogued.

## G12 — `pattern:` strings (already formal)

The one sub-grammar inside Bluebook that was ALREADY fully declared as
data before this document: `Hecks::Bluebook::PatternSubset`
(`lib/hecks/bluebook/pattern_subset.rb`) states, by name, exactly which
regex constructs a declared `pattern:` may use — explicit ranges,
alternation, quantifiers, anchors (`^`/`$` as LINE anchors), and
groups — and which it refuses and why: backreferences and named
backreferences (not linear-time), lookahead/lookbehind/atomic
groups/possessive quantifiers (the same reason), and Perl (`\d`/`\w`/
`\s`) or POSIX (`[:digit:]`) character classes (every engine reads them
differently — ASCII in some, Unicode in others). Mirrored byte-for-byte
in `rust/parser/src/build/pattern_subset.rs` and enforced at evaluation
time by `rust/src/kernel/pattern.rs`. Its own accept/reject corpus
already exists — `spec/corpus/fixtures/patterns.json` — and is not
duplicated here.

## G13 — The accept corpus and the contract it enforces

`spec/corpus/grammar/*.json` — one fixture per G4–G11 shape (and every
precedence-sensitive combination worth pinning on its own, like G4.3's
negation ordering), each carrying:

```json
{
  "grammar": ["G7"],
  "canonical": "!tags.include?(forbidden)",
  "ruby_only": false,
  "note": "…",
  "expect_ast": { "op": "not", "expr": { "op": "include", "…": "…" } }
}
```

`expect_ast` is Ruby's own `Expression::AstJson.emit_predicate(canonical)`
— never hand-typed — re-derived fresh on every run
(`spec/grammar_corpus_spec.rb`'s non-`io` half) so a fixture can never
silently drift from what the Ruby engine actually answers today. The
`io`-tagged half wraps each `canonical` string in one scratch
bluebook's own `given`, runs it through `hecks-parse chapter`, and
compares hecks-parse's own emitted `ast` against the SAME frozen
`expect_ast` directly — agreement on structure, not merely "didn't
crash." **The contract this corpus enforces**: `hecks-parse` is
authoritative by THIS grammar, not by parity with whatever Ruby happens
to do — a fixture citing a real gap (G11) says so explicitly and is
excluded from the comparison by name, never silently; anything Ruby
accepts that this document does not describe, and that a future fixture
catches diverging, becomes a new G-clause, not a quiet widening of an
existing one.
