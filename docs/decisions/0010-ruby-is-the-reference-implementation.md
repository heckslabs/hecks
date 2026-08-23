# Ruby is the reference implementation; other runtimes validate against it, continuously

**Status:** Accepted — not yet implemented. Supersedes the "wait for IR stability" entry criterion in [0007](../implemented/decisions/0007-rust-generates-code-not-ruby-source.md)'s original Phase 5 placement.

## Context

[0007](../implemented/decisions/0007-rust-generates-code-not-ruby-source.md) committed Rust to being a code generator over canonical IR, not a hand-written interpreter — closing the failure mode that killed the retired Rust runtime (a second parser/dispatcher/evaluator kept in differential parity *by hand*, forever, as Ruby changed). Having settled that, the roadmap still gated Rust behind Phases 2–4 (Governance, Identities, `act_as`, UL projection, a proven canonical corpus) landing first, reasoning that starting codegen against IR that's still gaining shape would mean regenerating and recompiling repeatedly against a moving target.

That reasoning conflated two different risks. Eras mean canonical IR *always* keeps changing — that's the premise the whole system is built on, not a temporary condition to wait out. The actual cost the retired runtime paid wasn't "the target changed"; it was "a human had to notice the target changed and manually re-derive the second implementation's behavior, with nothing mechanical checking they'd gotten it right." A generator, by construction, doesn't have that problem the same way: regenerating from new IR is cheap and mechanical. What was still missing was a way to know, cheaply and continuously, whether the *generated* result actually behaves like Ruby — without that, "regenerate and hope" is barely better than the thing 0007 already rejected.

The fix is to make Ruby do double duty it's already positioned for: it's the existing, working implementation, so it can serve as both the spec an implementer reads to know what to build, and the oracle a differential test suite checks the result against. Once that oracle exists and runs continuously, IR churn stops being a reason to wait — it becomes a normal, bounded, immediately-verified increment: extend the generator (and, when a change is behavioral rather than shape-only, the small hand-written kernel), run the harness against the existing corpus, fix whatever it flags.

## Decision

**Ruby is the reference implementation for every other runtime this project builds**, in two roles at once:

1. **Implementer's guide.** Ruby's actual behavior — not just canonical IR's shape — is what a second runtime's generator and kernel are built to reproduce. When a construct's behavior isn't fully pinned down by IR alone (evaluation order, refusal wording, edge-case coercion), Ruby's implementation is the tiebreaker, not a fresh design decision.
2. **Correctness oracle.** A differential test harness dispatches the same command sequences — drawn from the existing corpus (`spec/corpus/*.json`) and the fuzzer (`Fuzzing::SequenceGenerator`/`Fuzzing::Replay`) — into both Ruby and the second runtime, and diffs accepted/refused outcomes, refusal wording, emitted events, and resulting record state. This harness is the actual gate for shipping or extending a second runtime — not a roadmap phase boundary.

This replaces 0007's original "Rust doesn't start until Phases 2–4's IR is stable and corpus-proven" gate. Rust — and any future non-Ruby runtime — can start now, against whatever IR exists today, and extend incrementally in lockstep as later phases land: each new Ruby-side feature (Governance, `act_as`, UL projection, ...) gets a fast-following update to the generator and, where the change is behavioral rather than purely shape, the hand-written kernel — verified by the same harness before it counts as done. Rust never falls silently behind; there is no "wait until everything settles, then build it all at once" cliff.

## Consequences

- The differential harness is now a first-class, early deliverable — building it comes before generating any real Rust code, since without it "the generator produces plausible-looking output" and "the generator produces *correct* output" are indistinguishable.
- §8's roadmap placement moves from a late, gated phase to an early one that runs concurrently with authority/identity/ontology work, not sequentially after it.
- Every later phase that changes canonical IR or dispatch-pipeline behavior (Governance, `act_as`, UL projection/provenance, and beyond) now has an implicit, standing obligation: extend the second runtime and re-run the harness in the same or a fast-following change, not as separately-scheduled catch-up work.
- This principle isn't Rust-specific. Any future runtime (WASM's host, or something further down the roadmap) inherits the same two roles for Ruby — guide and oracle — rather than each needing its own bespoke validation story.
- The hand-written kernel surface still needs human attention when Ruby gains new dispatch-pipeline *behavior* (not just new IR shape) — that cost doesn't disappear, but it's small by 0007's own design, and the harness catches drift in it immediately rather than letting it accumulate.

## Rejected alternatives

- **Keep the original phase-gated entry criterion.** Rejected as solving the wrong problem: it protected against IR churn, but churn was never the expensive part — hand-maintained, unverified parity was. A continuously-run oracle addresses the actual cost directly.
- **Validate only once, at the end of each phase, rather than continuously.** Rejected because it reintroduces exactly the "build it all, then discover the gaps" cliff this decision exists to avoid — the value is in catching drift at the moment it's introduced, not in a periodic audit.
- **Treat Ruby's behavior as advisory and let the second runtime's design diverge where convenient.** Rejected — the whole point of a second runtime is behavioral equivalence with the first; treating Ruby as merely a suggestion reopens the door to exactly the kind of silent semantic drift 0007 and this decision both exist to prevent.
