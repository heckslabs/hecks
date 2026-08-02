# The expression sublanguage — a formal grammar

Every `given`, `invariant`, and where-clause literal value in a `.bluebook` domain is canonical
text — a `Proc` lowered by Ruby's own parser (Prism) at DSL-build time, never a closure carried
across the runtime boundary. Both runtimes evaluate the *text*. This document is the grammar that
text has to obey, written so a third implementation doesn't have to reverse-engineer it by reading
two independent pieces of regex/string-matching code side by side
(`lib/hecksagain/bluebook/expression/{evaluator,resolver}.rb` and
`rust/src/bluebook/expression/{evaluator,resolver}.rs`).

It's organized as two grammars, stacked: an **outer** boolean/comparison grammar, whose leaves are
resolved by an **inner** arithmetic/dotted-lookup grammar. Both are recursive-descent, precedence
encoded as check order — the first pattern that matches wins, so order *is* the grammar.

A related but different artifact: `lib/hecksagain/grammar/expression.bluebook` is the language's own
self-description of admitted operators as *data* (an `Operator` aggregate with a `proposed →
admitted → retired` lifecycle, tracking precedence/category/arity/renderings per operator). It used
to be a content-management domain about operators that nothing read; it is now **held to the parser
by checking**: `lib/hecksagain/grammar/expression_operators.json` replays every operator through the
chapter's own Propose → Render (ruby, rust) → Admit commands, and `spec/operator_conformance_spec.rb`
holds the evaluator's tables equal to the admitted set, both directions — an operator the ledger
never admitted does not exist to the evaluator. This document remains the parser's spec; the
chapter is the ledger the parser is audited against.

## Outer grammar (boolean / comparison)

Checked in this order — each returns as soon as it matches:

1. **Parenthesization.** A leading `(` matched by a trailing `)` with balanced depth strips to its
   contents and recurses (`strip_parens`). A partial wrap — `(1 < 2) && (3 < 4)` — is left alone;
   only a *whole-expression* wrap is unwrapped.
2. **`||`** — the loosest binding. Split at the first top-level `||` (outside parens and quotes);
   both sides recurse.
3. **`&&`** — binds tighter than `||`, looser than everything below. Same top-level split.
4. **`.include?(needle)`** — membership. The haystack (everything before `.include?(`) and the
   needle (the call's argument) are each parsed by the *inner* grammar below. Behavior is typed by
   the haystack's resolved value, per `Vocabulary::IncludeHaystack`
   (`lib/hecksagain/language/bluebook/vocabulary.bluebook`):
   - `Array` haystack → membership via the same `equal?` primitive comparisons use (numeric kinds
     equate across Integer/Float; a value never equals its own string form).
   - `String` haystack → substring match; a non-`String` needle is refused
     (`"no implicit conversion of #{class} into String"`), not silently coerced.
   - Anything else → always `false` (the fallback every other haystack type shares, not a case of
     its own — not separately declared in the vocabulary for that reason).
5. **The six comparators** — `>=`, `<=`, `<`, `>`, `==`, `!=`. Checked in that order against
   `Vocabulary::Comparison`'s table (same file), which reduces all six to two primitives —
   `less_than` and `equal` — combined by a tiny boolean algebra rather than a six-way case:

   | symbol | compares_less_than | compares_equal | negated |
   |---|---|---|---|
   | `>=` | true | false | true |
   | `<=` | true | true | false |
   | `<` | true | false | false |
   | `>` | true | true | true |
   | `==` | false | true | false |
   | `!=` | false | true | true |

   `apply(op, lhs, rhs) = (op.compares_less_than && less_than(lhs,rhs)) || (op.compares_equal &&
   equal(lhs,rhs))`, negated if `op.negated`. `less_than` compares two numerics (Integer/Float
   freely mixed) or two Strings lexically; anything else is refused
   (`"comparison of X with Y failed"`). `equal` compares numerics by value across kind, otherwise by
   Ruby-style `==` — a number never equals its own string spelling.

   Finding *which* operator matched requires care: splitting on `>` must not fire inside `>=`, and
   `==`/`!=` must not be mistaken for a stray `=` beside `<`/`>`/`!`. Both runtimes guard this with
   the same rule (`part_of_longer?`/`part_of_longer`): a split point is rejected if the character
   right after it is `=` and the operator itself doesn't end in `=`, or if the character right
   before it is one of `< > ! =` and the operator itself starts with `=`.
6. **`!expr`** — negation, tightest binding of all (binds tighter than `&&`/`||`, and the operand
   recurses through this same outer grammar, not the inner one — `!(a && b)` is valid).
7. **Fallback: a bare leaf.** Anything that matched none of the above is handed to the inner
   grammar and its truthiness decides the result — `nil` and `false` are the only falsy values
   (Ruby's own rule, not a superset or subset of it: `0` and `""` are both truthy).

## Inner grammar (leaf: arithmetic / dotted lookup)

Every `Compare`/`Include`/bare-leaf operand from the outer grammar is a *string* handed to this
grammar. Checked in this order (identical in both languages as of this doc — see the note below on
why that took a small fix):

1. **`.length`** — folds directly to `.size` (rule 6 below); `.length` is not a separate node, it's
   sugar resolved at parse time.
2. **Integer literal** — `-?\d+` exactly.
3. **Float literal** — `-?\d*\.\d+` exactly.
4. **Quoted string literal** — wrapped in matching `"..."` or `'...'`; the quotes are stripped, no
   escape processing inside.
5. **`true` / `false` / `nil`** (Rust also accepts `null` as a `nil` synonym) — literal booleans and
   the null value.
6. **Top-level `+` addition** — split at the first `+` outside parens and quotes; both sides recurse
   through this same inner grammar and are each required to resolve to a number
   (`"addition expects a number, got …"` otherwise).
7. **Sign tests** — `.positive?`, `.negative?`, `.zero?` (`Vocabulary::SignTest`, same file). Each is
   sugar for comparing the receiver against the literal `0` using an operator `Vocabulary::Comparison`
   already declares — `positive?` → `>`, `negative?` → `<`, `zero?` → `==`. The receiver must resolve
   to a number or the test is refused (`"positive? expects a number, got …"`).
8. **`.empty?`** — receiver must resolve to one of `Array`/`String`/`Hash` (`Vocabulary::SizedType`),
   answering `.empty?`/`.length == 0` in the obvious way; anything else is refused
   (`"empty? expects a list or string, got …"`).
9. **`.to_s`** — receiver must resolve to one of `Vocabulary::ToStringType`'s six scalar types
   (`String`, `Integer`, `Float`, `TrueClass`, `FalseClass`, `NilClass`); renders exactly as Ruby's
   own `#to_s` would (`nil` → `""`, a bool → its name, a number → its digits — a Float that's a whole
   number still prints with one decimal place, e.g. `"3.0"` not `"3"`). Anything else is refused
   (`"to_s expects a scalar, got …"`).
10. **`.modulo(argument)`** — both receiver and argument resolve through this grammar and must be
    numbers; a zero divisor is refused (`"divided by 0"`), otherwise integer modulo
    (`receiver.to_i % divisor.to_i`).
11. **`.size`** — same admitted types as `.empty?` (`Vocabulary::SizedType`), answering length/count.
12. **Fallback: dotted lookup.** Split on `.`; the first segment is looked up first in the *argument*
    bindings (`attrs`) and, only if absent there, in the subject's own stored *state* — an argument
    always shadows a same-named stored value. Each further segment steps into the previous result as
    a key (symbol first, then string) if it responds to indexing, otherwise the whole lookup is
    `nil`. A name found in neither `attrs` nor `state` is refused
    (`"cannot resolve X — no such attribute or argument"`).

**On the check order above being identical in both languages**: it wasn't, until this doc was
written. Rust's resolver checked `.modulo(` before `.empty?`/`.to_s`; Ruby checked them in the
opposite order. Both are terminal, mutually-exclusive suffix/call-pattern matches (nothing can
simultaneously end in `.empty?` and match `.modulo(...)`'s `ends_with(')')` requirement), so this
was never observable in practice — but it meant the two reference implementations quietly disagreed
with each other on a rule this document is now the single source of truth for. Rust's order was
changed to match Ruby's so there is exactly one true order to read here, not an implicit "pick
whichever implementation you read first."

## Which rules are contractually fixed vs. incidental

Every `Vocabulary::*` cited above is declared in `lib/hecksagain/language/bluebook/vocabulary.bluebook` and
held equal to Ruby's live constant table by `spec/vocabulary_conformance_spec.rb` — those rules
cannot silently drift in the two existing implementations, and a third implementation gets the exact
same table for free from `rust/src/bluebook/expression/operators.json` (comparisons) and the
vocabulary declarations themselves (sign tests, include-haystack strategy, size/to_s admitted
types). Everything else described above (check order, the `+`/`.modulo(`/dotted-lookup mechanics,
error message wording) is real behavior but currently lives only in code — porting it correctly
means matching this document, then checking against `spec/expression_spec.rb`'s and
`rust/src/bluebook/expression/tests.rs`'s case lists (see `build-order.md`).

## Worked examples

- `"toppings.size.positive?"` — inner grammar: `.positive?` suffix strips first (rule 7), receiver
  `"toppings.size"` recurses, `.size` suffix strips (rule 11), receiver `"toppings"` recurses to a
  dotted lookup (rule 12). Evaluates to `lookup("toppings").size.positive?`, read inside-out.
- `"amount + adjustment >= 0"` — outer grammar: no `||`/`&&`/`.include?`, `>=` matches first among
  the six comparators (checked before `<=`/`<`/`>`), splitting into left `"amount + adjustment"` and
  right `"0"`. The left, handed to the inner grammar, hits the top-level `+` split (rule 6) before
  anything else, giving `lookup("amount") + lookup("adjustment")`.
- `"!target.to_s.empty?"` — outer grammar: `!` matches last of the outer checks but binds tightest,
  wrapping everything after it — `"target.to_s.empty?"` recurses through the *outer* grammar again
  (not the inner one directly), finds no comparator/`.include?`, falls through to the bare-leaf case,
  which hands it to the inner grammar: `.empty?` strips first (rule 8, before `.to_s` would even be
  reached — `.empty?` matches the trailing suffix, `.to_s` is part of the *receiver* string being
  parsed, e.g. receiver `"target.to_s"` recurses to rule 9's `.to_s` case). Net:
  `!lookup("target").to_s.empty?`.
