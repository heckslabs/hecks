---
title: "Parity as Language-Neutrality Pressure: A Methodology for Cross-Language Systems"
authors: "Chris Young"
version: "paper/prior_use-v1-2026-04-24"
commit: "c4a903f3"
date: 2026-04-24
---

# Parity as Language-Neutrality Pressure

## A Methodology for Cross-Language Systems

**Version:** `paper/prior_use-v1-2026-04-24`
**Repository commit at time of writing:** `c4a903f3`
**Author:** Chris Young

## Abstract

Systems that span multiple programming languages — a daemon written in Rust
consuming data produced by a library written in Ruby, a server emitting JSON
that a TypeScript client deserialises — accumulate host-language idioms
silently. Symbol keys, hash coercion, trait-based dispatch, or lifetime-
shaped borrow patterns bleed into the wire format and bias the system
toward its first host. We report a methodology in which a *parity test
suite* — a corpus of fixtures whose canonical IR is produced by both
language runtimes and asserted byte-equal — is maintained as a first-class
artefact of the system. The methodology's primary purpose is drift-catching
between runtimes. Its deeper and longer-running benefit is *language-
neutrality pressure*: because neither implementation may encode host-
specific idioms without breaking parity, the shared IR remains honest to
both languages. Language-neutrality is what later enables cross-language
specialisation, target-language addition (Go, WebAssembly), and the
deletion of one runtime in favour of the other (as reported in Paper 3 of
this collection). The empirical cost is approximately a 15–20% tax on
feature-landing time. The empirical benefit is that the IR is cheap to
specialise across languages — an outcome that would otherwise have required
a separate porting effort, which the methodology obviates. We place the
technique in the public record as prior art.

---

## §1 Introduction

A cross-language system can be organised in one of three ways.

First, **one-runtime-with-bindings**. The authoritative implementation is
in one language; other languages access it through FFI bindings. The IR,
if one is even named, is whatever the authoritative runtime produces.
Examples: most database clients, most serialisation libraries with
language bindings.

Second, **shared-parser-with-backends**. A parser generator or shared
grammar produces parsers in each target language; the IR is whatever the
parser generator emits. Examples: tree-sitter, ANTLR.

Third, **parity-first**. Each language has its own hand-written parser
and its own hand-written canonicaliser for the shared IR. A test suite
asserts byte-equality between canonicalisers over a shared corpus of
fixtures. No language is authoritative; the corpus is.

The third organisation has the highest per-feature cost (every new IR
feature lands in three sites — two parsers and the fixture — rather than
one). It also has, we argue, the highest long-run flexibility. This paper
explains why, reports the empirical cost and benefit from the Hecks
project, and describes the methodology in portable terms so that other
cross-language systems can adopt it.

### §1.1 Contribution

The contributions are:

1. **A methodology for cross-language IR maintenance.** Two hand-written
   canonicalisers, a shared fixture corpus, byte-equal assertion, and
   soft/hard drift partitioning (§3).
2. **An argument that parity's primary benefit is *language-neutrality
   pressure*, not drift-catching** (§4). Drift-catching is the surface
   effect; the structural effect is that host-language idioms cannot
   enter the IR.
3. **Two counterfactual arguments** (§5) showing that single-language
   projects cannot produce the same IR honesty, even in principle.
4. **An empirical cost account** (§6): ≈15–20% tax on feature-landing
   time, measured across the Hecks project's DSL-touching work.
5. **An empirical benefit account** (§7): a cross-language specialiser
   (Ruby → Rust) that reached byte-identity on first run, a phase
   (Phase E of the Hecks autophagy arc) that was trivially deletable
   once the specialiser shipped, and an open path to further target
   languages without reshaping the IR.
6. **Four portability recommendations** (§8) for teams considering the
   methodology.

### §1.2 Paper organisation

§2 states the problem. §3 describes the methodology. §4 describes the
language-neutrality pressure claim. §5 presents counterfactuals. §6 is
the cost account. §7 is the benefit account. §8 offers portability
recommendations. §9 surveys related work. §10 enumerates novel claims.
§11 closes.

---

## §2 The Problem: Silent Idiom Drift

A cross-language system that begins in one language and acquires a second
accumulates idioms from the first. The pattern is almost invisible at the
point of commit and costly at porting time.

A concrete Hecks example, pre-parity. The Ruby canonicaliser represented
command references with symbol keys: `{ target: :Account, as: :owner }`.
Deserialising the same IR in Rust required the Rust parser to carry a
notion of "Ruby symbol" as a distinct type from "Rust string" — a notion
Rust does not natively have. The Rust parser accumulated helper types
and conversions to preserve round-tripping. The IR was not Ruby-specific
in its *description*, but it was Ruby-biased in its *practice*: a
third-language port would have had to carry the same distinction even
though it was an artefact of the first language.

The bias compounds. A wire format that uses Ruby-specific types to
represent references uses Ruby-specific types to represent attribute
defaults, then Ruby-specific patterns to represent policy subscriptions,
and eventually the IR is a serialisation of the Ruby implementation
rather than a specification of a domain. Any cross-language user pays
the tax.

The problem is not unique to Ruby. A Rust-first project's IR
accumulates result-type wrappers, borrow shapes, and trait-object
hierarchies that a second-language port has to translate away. A
TypeScript-first project accumulates structural-typing and optional-
chaining patterns. Every host language biases its IR unless something
actively prevents the bias from entering.

Parity, maintained as a first-class artefact, is the something.

---

## §3 The Methodology

The parity methodology has four components. We describe each in portable
terms; §7 gives the Hecks-specific evidence.

### §3.1 Two hand-written canonicalisers

Each language has its own canonicaliser — a function that takes the
language's parsed representation of a source file and emits the
canonical IR. The canonicalisers are hand-written, not generated; they
are owned by engineers working in each language.

In Hecks: `hecks_life/src/dump.rs` (Rust, 180 lines of code) and
`spec/parity/canonical_ir.rb` (Ruby, comparable size). Both emit keys in
the same order, normalise nullables the same way, and stringify types
the same way. Parity is defined as byte-equal output from the two
canonicalisers for the same input file.

The *hand-written* property is load-bearing. A generator that emits
both canonicalisers from a shared specification collapses the
methodology back into shared-parser-with-backends (§1); the two
implementations no longer have independent intuitions. The point of
having two is that they reach the same answer by different paths; if
the paths are forced to be the same, the parity assertion is vacuous.

### §3.2 A shared fixture corpus

A directory of source fixtures, each of which exercises a specific
feature of the grammar. The corpus is run through both canonicalisers
on every commit; their outputs are diffed; a byte difference is a
failure.

In Hecks: `spec/parity/bluebooks/` + `spec/parity/hecksagon/` + siblings
hold 920 fixtures across five DSLs. Each fixture is a standalone file
that both parsers can read independently.

### §3.3 Soft/hard partitioning

Not every fixture must pass. Some domains are speculative prototypes
(`hecks_conception/nursery/` in Hecks) whose failure is interesting but
not blocking. Others (the hard corpus) must pass or the commit is
rejected.

The partition is maintained by directory or by explicit listing. In
Hecks, hard fixtures include the synthetic edge-case fixtures, the real
aggregate bluebooks, the capability bluebooks, and the catalog
bluebooks — 129 at the time of this writing, all passing. Soft
fixtures are the nursery (368/375 passing).

A `known_drift.txt` file names the specific soft-corpus fixtures that
are known-failing, with a one-line note each. A fixture in
`known_drift.txt` that passes is reported with a `⚑` status — not a
failure, but a prompt for the developer to remove the entry. This
prevents `known_drift.txt` from silently accumulating.

### §3.4 Byte-equal canonicalisation as the assertion

Not *semantic equivalence*, not *functional equality* — byte-equality.
This rules out whitespace differences, key-order differences,
numeric-representation differences, and any other cosmetic drift.
Byte-equality is uncomfortable at first; it rejects a lot of
cosmetically-harmless divergence. That is the point. Cosmetically-
harmless divergence today becomes the crack through which host-language
idioms enter tomorrow.

---

## §4 The Deeper Benefit: Language-Neutrality Pressure

Drift-catching is the methodology's surface effect: a parity suite
catches bugs in one parser that the other parser does not exhibit. Real
Hecks parity-suite drift history documents four Rust-parser bugs and
one Ruby-builder bug landed in a single commit,
`parity: 113/113 — fix 4 Rust parser bugs, drain known_drift`.

The deeper effect — visible only in retrospect after a cross-language
system has lived for more than a year — is that parity forces the
canonical IR to be language-neutral. Because two implementations must
produce byte-identical canonical output, neither is permitted to encode
idioms specific to its host language. The IR becomes an honest contract
rather than a convenient intermediate representation biased toward one
runtime.

This pressure compounds over time. A feature added to the IR in year
one that used symbol keys would have produced parity failures on the
Rust side; the developer would have refactored to a neutral
representation before committing. A feature added in year two builds on
the neutral year-one representation, so year-two's IR stays neutral.
Year three lifts another layer (partial evaluation, cross-language
specialisation); that lift is cheap because the IR it consumes was
language-neutral from the start.

The claim has structure. Language-neutrality pressure is a *second-
order* property of parity: parity directly enforces byte-equality;
byte-equality *permits only* language-neutral encodings; so parity
*indirectly enforces* language-neutrality. The path from parity to
language-neutrality is not stipulated — nobody writes a rule that says
"no symbol keys." The rule is discovered by developers whose commits
fail parity when they try to write non-neutral code.

---

## §5 Counterfactuals

Two counterfactuals make the claim concrete.

### §5.1 In a Ruby-only project

In a Ruby-only project, the IR would accrete Ruby idioms silently —
symbol keys, `send`-style dispatch, implicit hash coercion — and a
later cross-language port would surface those idioms as bugs *at port
time*, rather than *at parity time*. The port would be expensive
exactly in proportion to how many years the IR had accreted idioms.

In a Ruby-only project, the *antibody* (the mechanism that rejects
sixth DSL extensions in the Hecks codebase — Paper 1 of this
collection documents it) would also have no teeth. Ruby code is easy to
smuggle into a Ruby project when there is no second interpreter to
fail on it. The antibody's power comes from the second interpreter that
will try to parse the new extension and fail.

### §5.2 In a Rust-only project

In a Rust-only project, the host-language integration story disappears:
there is no Rails-style `Hecks.configure` binding, no Ruby agent
ecosystem around the daemons, no diversity pressure keeping the IR
honest. The IR would accrete Rust idioms — result-type wrappers in
wire format, lifetime-shaped helper types, trait-object-style
dispatch — that later additions to other languages would have to
translate away.

A Rust-only project also lacks the *authoring affordance* Ruby
provides. The `.bluebook` file as executable Ruby *and* inspectable
data — the property that makes a domain file runnable from `ruby
-Ilib` and parseable by a Rust binary — is a consequence of Ruby's
metaprogramming. A Rust-only system would need a parser and a separate
execution model for what Ruby gives for free.

### §5.3 The counterfactual is about permissiveness

The two counterfactuals share a structural property: without a second
runtime to fail on non-neutral encodings, there is no mechanical
pressure toward neutrality. Discipline can substitute — a team can
pledge to keep the IR neutral — but discipline decays. A test that
fails on the next commit does not.

---

## §6 Empirical Cost: ≈15–20% Tax

The cost of parity is measurable. Across the Hecks project's DSL-
touching work, the per-feature overhead is approximately a 15–20% tax
on implementation time. That is the difference between landing a
feature in one site versus three (two parsers and the fixture), plus
the per-feature fixture authoring and the runtime of the parity suite.

### §6.1 What counts as a feature

A *feature* in this accounting is a new IR field, a new grammar
construct, or a new canonical-form rule. Examples from Hecks:

- Adding `as: :<alias>` to a `reference_to` (one IR field, three
  sites).
- Supporting `list_of(X)` where `X` is a value object (one IR field
  plus one normalisation rule, three sites plus one fixture).
- Adding lifecycle transitions to the grammar (one construct, three
  sites plus five fixtures covering edge cases).

### §6.2 The cost curve

The cost is highest for the first feature of a new kind — defining a
new check in a canonicaliser, say, when the canonicaliser has no
precedent for it. Subsequent features of the same kind are cheaper
because the canonicaliser's structural scaffolding exists.

### §6.3 The cost is paid on the build loop

Parity runs in approximately one second against the full corpus, so
iteration is fast. A developer edits a parser, re-runs the suite, and
sees the exact fixture that diverges. The cost is paid in
implementation time, not in build time.

### §6.4 The cost is paid by the feature author

A feature lands in three sites because the feature author touches three
sites, not because three authors touch one site each. This property
matters: parity is not a coordination cost across teams; it is an
additional surface for a single engineer. That makes the cost
predictable — the author can estimate it up front and spend it
voluntarily.

---

## §7 Empirical Benefit: The Phases that Parity Enabled

The cost account above is what parity *buys*. This section describes
what it *bought* in the Hecks project, as of commit `c4a903f3`.

### §7.1 Phase A-C: declarative specialisation with byte-identity

Paper 3 of this collection reports that Hecks retired a Rust module
(`validator.rs`) by declaring its shape as data and regenerating the
module byte-identically. The fact that a byte-identical regeneration
was *possible* depended on the IR being language-neutral enough that
the shape declaration had no host-language assumptions to translate.
Parity paid for that. Without parity, the shape would have accreted
Ruby idioms (because the specialiser was Ruby-authored), and the
regeneration in Rust would have had to translate them at every run.

### §7.2 Phase D: cross-language specialiser port with first-run byte-identity

The stronger evidence. Phase D ported Hecks's specialiser from Ruby to
Rust. The test — that the Rust specialiser produces byte-identical
output to the Ruby specialiser — passed on the first run. This is
unusual. Cross-language ports usually require rounds of adjustment as
host-language-specific behaviours are discovered and translated. The
first-run pass was not a lucky coincidence; it was structurally
guaranteed by years of parity work that had already forbidden any
Ruby-specific or Rust-specific assumption from entering the specialised
cache.

### §7.3 Phase E: deletion

Once the Rust specialiser shipped, the Ruby specialiser was deletable.
Phase E removed `bin/specialize`, `lib/hecks_specializer.rb`, the 16
Ruby specialiser modules under `lib/hecks_specializer/`, and the five
Rust meta-specialisers that had been emitting Ruby files. Net deletion
was approximately 3,000 lines.

The deletion was cheap because the Ruby specialiser had no behaviours
the Rust specialiser did not match byte-identically. If the IR had
accreted Ruby-specific encodings over the years, Phase E would have
required an additional translation layer or a compatibility shim; the
3,000 lines would have moved rather than being removed. The language-
neutral IR made deletion the simplest possible refactor: remove the
files, watch the tests pass.

### §7.4 The outcome that was not available without parity

None of Phases A through E would have been available without parity —
not in the sense that they would have been more expensive, but in the
sense that the shapes they exploit would not exist in their current
language-neutral form. A Ruby-idiom-bearing IR has no free cross-
language specialiser. A Rust-idiom-bearing IR has no Ruby authoring
surface. Parity kept both options open, at a cost of ≈15–20% of
feature-landing time, for long enough that the arc became available to
ship.

### §7.5 The framing inverted

The framing is therefore: parity's real purpose was never redundancy.
Redundancy is the surface effect. The real purpose was to keep the
specification language-neutral before any programme attempted to exploit
that property. The work that ends parity — the deletion of one runtime
in Phase E — is only possible because parity existed.

---

## §8 Portability Recommendations

For teams considering this methodology on their own cross-language
systems:

### §8.1 Define parity early, even if redundant

Maintain parity from the point the system has two language-facing
surfaces, even if one is clearly secondary. Retrofitting parity onto
a system whose IR has already accreted idioms is much more expensive
than maintaining it from the start. The ≈15–20% tax is for systems
that started with parity; a retrofit would likely double this for the
first year as idioms were unwound.

### §8.2 Make fixtures cheap to author

If authoring a fixture is a 30-minute chore, developers will skip
fixtures and parity will decay. Hecks fixtures are single files that a
developer can copy, edit, and save in under two minutes; the parity
suite picks them up automatically. The methodology depends on the
fixture authoring being as friction-free as editing the feature.

### §8.3 Soft/hard partition matters

Without a soft partition, every experimental fixture blocks the
pre-commit hook; developers disable the hook. Without a hard partition,
real regressions hide in noise. The celebrate-and-remove semantics on
`known_drift.txt` prevents the soft section from silently accumulating.

### §8.4 Byte-equality, not semantic equivalence

The temptation is to assert *semantic* equivalence — "same meaning,
allow cosmetic differences." Resist it. Cosmetic differences are how
host-language idioms enter the IR. Byte-equality is harsh but
mechanically enforces neutrality; semantic equivalence is lenient and
permits drift.

### §8.5 Expect the benefit to arrive late

The drift-catching benefit arrives early — a parity suite catches
bugs in its first week. The language-neutrality-pressure benefit
arrives late, typically when an adjacent programme (specialisation,
cross-language port, additional target language) turns out to be
cheaper than expected. A team that does not have such a programme in
view may reasonably question whether the 15–20% tax is worth paying.
The answer depends on whether the team expects to ever want the
option of exploiting language-neutrality. Hecks did not plan the
partial-evaluation arc when parity began; the arc became available
because parity had been maintained. The option value is what the tax
buys.

---

## §9 Related Work

**Shared grammars via generators.** tree-sitter, ANTLR, PEG.js. These
produce parsers in multiple target languages from a shared grammar.
The IR they yield is structurally the same across languages by
construction. The cost is that the parsers are generated, not hand-
written, so the independent intuitions that parity-as-methodology
depends on are absent. Idioms that leak through the generator into the
target-language runtime are harder to catch.

**Schema-first languages.** Protobuf, Avro, JSON Schema. These describe
wire shapes; parity is enforced by the schema itself. The distinction
from parity-first parsing is scope: Protobuf governs serialisation,
not parsing. A language's parser can still encode idioms that don't
show up in the schema — for instance, how a parser represents the
source file structurally before serialising.

**Interop-oriented standards.** WASM, LLVM IR. An IR designed
explicitly to be language-neutral, produced by many compilers. This is
the end state parity-first systems aim at, achieved in interop-
oriented standards by the IR being the point of the system. In Hecks,
the IR is a means, not an end; parity is what keeps it honest.

**Cross-language testing.** Rails tests its JavaScript integration
against a live browser, not against a reimplementation. The shape is
different: one language is authoritative, the other is exercised via
integration tests. Parity-first does not privilege either language;
both are exercised against the same corpus with the same strictness.

**Bootstrapping compilers.** `rustc`, GHC. These are cross-phase (not
cross-language) systems in which the same language is run by different
compilers. Byte-identity across bootstrap iterations is a related
discipline. Parity-first applied cross-language is a different scope.

---

## §10 Techniques and Novel Claims

1. **Parity as a methodology, not a tactic.** Hand-written
   canonicalisers in two (or more) languages, a shared fixture corpus,
   byte-equality assertions. The shape is portable beyond any specific
   project.
2. **Soft/hard partitioning with celebrate-and-remove drift
   semantics.** `known_drift.txt` lists expected drifts; a listed
   fixture that starts passing is reported with a `⚑` status so the
   developer deletes the entry rather than leaving it to rot.
3. **The claim that parity's primary long-run purpose is language-
   neutrality pressure, not drift-catching.** Drift-catching is the
   surface effect; neutrality is the structural consequence.
4. **An empirical cost account: ≈15–20% tax on feature-landing
   time** for the parity-first organisation. Paid by the feature
   author, on the local build loop.
5. **An empirical benefit account: first-run byte-identity on a
   cross-language specialiser port.** Phase D of the Hecks autophagy
   arc reached byte-identity on the first run because years of parity
   had already forbidden host-specific encodings.
6. **The deletion outcome: parity ends parity.** Once language-
   neutrality is sufficient to specialise across languages, one
   runtime can be removed (Phase E of the Hecks arc) because the
   shapes it exploits are now host-neutral by construction.
7. **The four portability recommendations of §8.** Define parity
   early; make fixtures cheap; soft/hard partition; byte-equality not
   semantic equivalence; expect the benefit to arrive late.

---

## §11 Conclusion

Parity between hand-written canonicalisers in two languages, asserted
byte-equal against a shared fixture corpus, is costly — approximately
15–20% of feature-landing time in the Hecks project. Its visible
benefit is drift-catching: bugs in one language's parser are caught
before they ship. Its longer-running and less visible benefit is
language-neutrality pressure on the IR, which keeps options open for
cross-language specialisation, additional target languages, and
runtime deletion. The methodology is portable. We place it in the
public record as prior art at commit `c4a903f3`. Reference
implementation: `spec/parity/`, `hecks_life/src/dump.rs`,
`spec/parity/canonical_ir.rb`, `spec/parity/known_drift.txt`.
