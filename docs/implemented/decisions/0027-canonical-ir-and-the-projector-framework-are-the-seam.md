# Canonical IR and the Projector framework are the seam; unbuilt work projects it, and the verification set protects trust in it

**Status:** Accepted, and mechanized. Names a pattern already true of the
done work and already implied by the unbuilt work's own names in
[`HECKS_IMPLEMENTATION_PLAN.md`](../HECKS_IMPLEMENTATION_PLAN.md). The
"is this a projector?" question is now an enforced gate
(`spec/projector_seam_spec.rb`), not just a question someone has to
remember to ask — the rest of this ADR governs how future roadmap items
get *scoped*, which the gate cannot do on its own.

## Context

`HECKS_IMPLEMENTATION_PLAN.md` lists 34 numbered features, sequenced into
10 phases. Read flat, as an ordered backlog, it doesn't say anything about
*why* that order, or what any two non-adjacent items have in common. Read
against what's actually done versus not, a seam is visible that the
document's own phase numbering doesn't name.

**Six of the thirteen done items are specifically the substrate that makes
canonical IR a real, reusable thing to build on, not an implementation
detail:**

- §7 Canonical IR as durable source format — IR gets its own version
  envelope, distinct from a domain's own `version:`, golden-tested.
- §33 Semantic identity/provenance — provenance edges attach *to IR nodes
  themselves*.
- §30 Projector architecture — `Hecks::Projector.register(name,
  projector)`, a generic registration mechanism, not one bespoke exporter
  per consumer.
- §31 Port fulfillment graph — models which ports a domain's own bindings
  satisfy, off the same IR.
- §3/§4 Governance/Identities Bluebooks — the authority and identity
  semantics a provenance edge or a projected artifact needs to actually
  mean something.
- §8 Rust projection — the substrate's own proof of load: Rust *generates
  from canonical IR at build time* and never parses or interprets it live
  ([0007](0007-rust-generates-code-not-ruby-source.md)).

**Nineteen of the thirty-four items are not started, and most of them name
what they are in their own title:** §15 UL *Projection* · §26 Historical
analytics/reports *by Era* · §27 Data engineering *projections* from
reports · §12 OIDC provider *projection* · §23 ISO discovery *and
projection* · §25 Historical runtime query *by Era*. §21/§22 (drift
detection, ontology upgrades) are two projections of the same IR at
different times, diffed. §17–§19 (Onboarding, role mapping review,
existing-role discovery) are UL Projection's own downstream consumers, not
a separate mechanism. The genuinely non-projection remainder is small: §1
(a guard), §14 (a domain-modeling decomposition), §28 (an authoring
practice — but one that exists specifically to give the projectors
something real to project), §13 (an adapter).

Separately, [`docs/prds/`](../prds/) scopes a set of verification
initiatives against the runtime and parser (unguarded concurrency,
Memory-only fuzzing, no cross-adapter mutation agreement, no fuzzed
Ruby/Rust conformance, thin numeric-boundary coverage, zero parser
fuzzing, no mutation-testing harness, no coverage-guided generation). Those
read, at first glance, as an unrelated QA track sitting beside the feature
roadmap. They are not unrelated.

## Decision

**Canonical IR plus the Projector framework is the one seam nearly
everything else in this project either builds, or stands on.** Two
consequences follow directly.

### A new roadmap item is evaluated as "is this a projector?" first

Before scoping any of the 19 not-started items — or a genuinely new
feature request that isn't on the list at all — ask whether it's
structurally a new `Projector` reading canonical IR plus provenance,
registered the same way §30 already made generic. Most of the roadmap
already answers yes. Treating each as its own bespoke subsystem instead
would mean re-deriving IR traversal, provenance reading, and export
plumbing 19 separate times — the same mistake
[0007](0007-rust-generates-code-not-ruby-source.md)/[0010](../../decisions/0010-ruby-is-the-reference-implementation.md)
already rejected once, for Rust specifically, one level up: a second,
hand-maintained implementation of "read the IR and do something with it,"
kept in parity by hand instead of sharing the one real mechanism.

### The verification set is not a side quest — it's what every projector trusts without re-checking

A `Projector` reads *stored state*; it never re-derives correctness from
first principles. If dispatch silently misapplies a mutation, or Ruby and
the Rust-generated runtime disagree about what a command did, or an
adapter stores a value differently than another — no projector downstream
will ever notice, because noticing isn't its job. The more the roadmap
executes on the seam above (more projectors, reading the same substrate),
the larger the blast radius of exactly the class of bug `docs/prds/`
scopes: one silently-wrong interpreter behavior becomes N silently-wrong
projected artifacts, not one. This is the same "two engines, compared"
discipline `spec/adapters/query_agreement_spec.rb` and this session's own
fuzzer property arc already established for the parts of the system that
existed before this ADR named the pattern — `docs/prds/` is that discipline
applied to the parts the pattern now says matter more, not less, as the
projection count grows.

### The gate is enforced, not just stated

`spec/projector_seam_spec.rb` is the mechanical half — the same move ADR
0026 already made turning "does the language use what it declares?" into
`spec/self_use_spec.rb`. It checks the one part of "is this a projector?"
that's actually mechanizable today: every file in
`lib/hecks/projections/` (the sanctioned home for a "canonical IR
in, external artifact out" tool) `extend`s `Projector::Target` and is
live in `Hecks::Projector`'s own registry — nothing sits there
declared but unregistered, and nothing registers a key without properly
extending the target contract. The two other kinds
`lib/hecks/projector.rb`'s own header already distinguishes — an
EXPORT (needs a declaration's bindings, which a projection's own call
shape has no channel for) or a STATE PROJECTION (reads records, not a
declaration) — get a named, reasoned roster instead of a bare exemption
list, checked against the real files still existing, the same
`META_DOMAIN_KNOWN_GAPS` discipline `spec/fuzzing/
meta_domain_coverage_spec.rb` already holds the language's own grammar to.

This gate found something real on its own first run: `lib/hecks/
projections/ir.rb` extends `Projector::Target` via `IR.extend(Projector::
Target)` — a real, legitimate method-call form every sibling file instead
spells as a bare `extend Projector::Target`. The gate's own first
regex silently skipped it rather than verifying it; a second, differently-
shaped check (scanning for `projects_as` first, then checking for the
extend) caught the gap. Fixed before landing, and left as its own comment
in the spec — the pattern this whole document argues for held even one
level down, in the checker meant to enforce it.

**What the gate does not yet do**, named rather than silently scoped
around: it doesn't scan `bin/` or the rest of `lib/` for a brand-new
script or module that reinvents "read a chapter's declaration, answer
something derived" *outside* `Projector::Target` entirely — the risk
`bin/expression_projection`'s own header already named for itself
("however much its name suggests otherwise"). Building that half
reliably needs a real signal for "looks IR-shaped" precise enough not to
false-positive across `bin/`'s three dozen other scripts, and wasn't
worth the risk of a fragile heuristic for this first version. The
`lib/hecks/projections/` directory convention plus this gate is the
practical stopgap: scoping a new projector there and following the
`Target` contract is the path of least resistance, which is most of what
matters day to day, even without a gate that would catch someone
deliberately going around it.

## Consequences

- **Scoping a new roadmap item starts with "what does it project, and off
  which IR/provenance shape."** A feature that can't answer that — or
  answers it awkwardly — is either genuinely novel (rare, given how much of
  the current list already fits) or a sign the feature needs to be
  re-cut, the same "cut from intent without opening the file" mistake ADR
  0026 names for `dsl-work-slices.md`'s own S14.
- **The verification set's priority doesn't decay as the "real" roadmap
  features land — it should trend the other way.** Each new projector
  registered is one more consumer trusting interpreter/parser correctness
  it never re-verifies itself. This reframes the coverage-guided-fuzzing
  PRD's own sequencing note in `docs/prds/` — wait until the real-adapter
  and Rust-conformance fuzzing PRDs widen the surface worth guiding
  toward — as an instance of a general rule, not a one-off judgment call.
- **The Projector framework (§30) becomes a de facto extension point for
  everything named "projection" in the roadmap** — any change to its own
  registration contract is now a change every future UL Projection,
  drift-detection, ISO discovery, or historical-analytics feature
  implicitly depends on, the same standing-obligation shape
  [0010](../../decisions/0010-ruby-is-the-reference-implementation.md) already establishes
  for the Rust generator against Ruby's own behavior.
- **This does not change any single PRD or roadmap item's own scope** —
  `docs/prds/` and `HECKS_IMPLEMENTATION_PLAN.md`'s §-numbered items stay
  exactly as written. This ADR names why they're one system, not two, and
  how to sequence future additions to either list.
- **`spec/projector_seam_spec.rb` is a real, running gate as of this
  ADR** — see "The gate is enforced, not just stated" above. `bundle exec
  rspec` fails if a file in `lib/hecks/projections/` is ever added
  without registering, or if the known-non-projection roster names a file
  that's since been renamed or deleted.

## Open, deliberately

- The gate's own named limit: it doesn't scan `bin/` or the rest of
  `lib/` for a brand-new tool reinventing "IR in, artifact out" entirely
  outside `Projector::Target` — see the gate's own section above for why,
  and what would need to be true for that half to be buildable without
  false-positive risk.
- Whether verification-PRD priority should be formally tied to a projector
  count (e.g., "N new projectors registered obligates a verification
  pass") rather than left as a sequencing judgment call each time. Not
  decided here.

## Rejected alternatives

- **Treat the 34 roadmap items as a flat, independently-scoped backlog.**
  Rejected — it's the reading that hides the seam, and the practical cost
  of hiding it is real: without naming the shared substrate, each of the
  19 not-started projection-shaped items risks being scoped as its own
  bespoke IR-reading mechanism instead of a `Projector` registration,
  repeating the exact mistake this project already spent
  [0007](0007-rust-generates-code-not-ruby-source.md)/[0010](../../decisions/0010-ruby-is-the-reference-implementation.md)
  settling for Rust.
- **Treat `docs/prds/` as separate, optional QA work, sequenced whenever
  convenience allows.** Rejected — it specifically protects the one thing
  every projector both depends on and never re-checks; deprioritizing it
  as "just tests" misreads what it's actually insurance against, and gets
  more expensive to have skipped the more projectors exist.
