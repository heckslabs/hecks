# The self-hosted language describes shape; the interpreter and IO stay hand-written

**Status:** Accepted — implemented (long-standing architecture; recorded here for the first time)

## Context

`MetaValidator.call` dispatches every real bluebook through the self-hosted `Bluebook` meta-domain (`lib/hecksagain/language/bluebook/`), and the graph that judging hands back — not the one the Ruby builder produced — becomes the actual runtime object (see [0001](0001-canonical-ir-is-runtime-independent.md)). Given how load-bearing that is, it's a fair question whether the self-hosted language is meant to describe the *whole* runtime — including evaluating a `given`/`ensures` predicate against a real record, and talking to adapters — or only the shape of a domain's static declaration.

The boundary is real, but it was previously stated in exactly one place: `bluebook.bluebook`'s own vision line — *"The floor that stays hand-written is the interpreter — evaluating a predicate held as data — and IO."* One sentence, in vision prose, in one of nine files that together declare the language. Nothing closer to where a reader would actually be reasoning about this (`meta_validator.rb`'s own header comment, this decisions directory, the roadmap) restated it.

The boundary is also reinforced structurally, independent of that sentence:

- **Ports/adapters are separate self-hosted chapters**, not aggregates inside Bluebook. `hecksagon.bluebook`, `adapter.bluebook`, and `world.bluebook` are judged through their own doors (`MetaValidator.call_world`, `call_adapter`) — IO isn't described by the Bluebook language because it structurally isn't part of it.
- **A command's rules are held as data, never as an evaluator.** `givens`/`ensures` are captured as `Rule` — a description plus canonical *text* — with no self-hosted "Interpreter" construct that says how to turn that text into a boolean against a real record. The language can say what a rule claims; evaluating it stays a Ruby proc.

This matters beyond documentation hygiene: [0007](0007-rust-generates-code-not-ruby-source.md) commits a second runtime to generating code from this same self-hosted shape. That only works cleanly if the shape/interpreter/IO boundary is something everyone can find and rely on — not an implicit convention that happened to be true because nobody had reason to cross it yet.

## Decision

The self-hosted `Bluebook` language describes **shape**: what constructs exist, what attributes they carry, what invariants must hold about a domain's *static declaration*. It does not, and will not, describe:

- **The interpreter** — how a `given`/`ensures` canonical-text predicate gets evaluated against a real record at dispatch time.
- **IO** — persistence, adapters, external port calls.

Both stay hand-written Ruby, deliberately and permanently, not as a gap awaiting a future self-hosting milestone. This was already true structurally (rules as text, IO as sibling chapters); it's now also written down as its own decision rather than left for a single vision sentence to carry alone.

## Consequences

- Any future runtime — Rust codegen per 0007, or anything after it — inherits exactly this split: the generator can be derived mechanically from the self-hosted shape description, but the interpreter (the `given`/`ensures` evaluator) and IO (adapters/ports) require their own hand-written kernel in that runtime too. Nothing about "the language is self-hosted" implies those get generated.
- A proposal to have the self-hosted language *also* describe evaluation semantics — e.g., representing `given` bodies as a self-hosted expression AST the meta-domain could itself evaluate, rather than canonical text plus a Ruby proc — would be a deliberate, scope-expanding decision, not an incremental extension. It should get its own ADR rather than accreting silently into this one.
- Anything documenting "what the self-hosted language covers" (onboarding material, future architecture docs) should point here rather than assume a reader will find `bluebook.bluebook`'s vision line unprompted.

## Rejected alternatives

- **Self-hosting the interpreter.** Representing `given`/`ensures` bodies as fully self-hosted, evaluable expressions instead of canonical text plus a Ruby proc. Rejected as out of scope here — canonical text is sufficient for judging and documentation; unifying it with actual evaluation is a materially larger project than describing shape, and isn't something this decision needs to resolve.
- **Folding IO into the Bluebook domain itself.** Already structurally rejected by the existing sibling-chapter design (`hecksagon.bluebook`, `adapter.bluebook`, `world.bluebook`, each with its own judge door) — kept separate so "what a domain says" stays cleanly apart from "how it talks to the outside world."
