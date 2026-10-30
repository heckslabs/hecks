# The sentence reader lives in its own repository and projects into bluebook

**Status:** Accepted.
Date: 2026-10-29.
Supersedes: 0131 §1 (the "not a separate language" clause) and 0131 §5 (one reader, in Rust,
inside this repository). 0131 §2–§4 and §6–§10 stand.

## Context

ADR 0131 let a `.bluebook` be written as plain sentences and kept the whole reader in this
repository: the grammar lives in the `Sentence` chapter, `rust/parser` is generated from it, and
`hecks-parse`, the formatter, `complete` and `hecks-lsp` are built beside the domain.

The reader's concerns (lexing, phrase matching, diagnostics, editor support) change on a different
rhythm from the domain, and another team could reasonably own or reuse them. What hecks needs from
the reader is narrower than the reader itself: a bluebook it can load.

## Decision

1. **The reader projects sentences into bluebook, not into the IR.** A sentence file goes in and
   Ruby-form `.bluebook` text comes out. The IR is what loading that text produces, and only hecks
   builds it. The reader never constructs, names or serialises IR, so it has no shared types with
   hecks.
2. **Hecks owns the contract.** The contract is:
   - the **phrase table** (`contract/phrases.json`), projected from the `Sentence` chapter, one row
     per phrase: `id`, `context`, `pattern`, `opens`, `status`;
   - the **mapping rules** (sentence to bluebook form), in `docs/sentence-contract.md`;
   - the **conformance corpus** under `spec/fixtures/sentence/`: each case is a sentence file and
     the bluebook text it must produce, byte for byte, with the hand-written Ruby twin that must
     load to the same IR.
3. **The reader lives in its own repository**, `heckslabs/hecks-gherkin`. It holds the lexer, the
   parser, the projection to bluebook, `complete`, the diagnostics and the editor server. It pins
   a contract version and does not depend on hecks' source tree.
4. **Hecks keeps loading.** `Hecks::SentenceForm` calls the reader's binary, writes the bluebook
   text it returns to the cache and loads it as it loads any `.bluebook`. Boot, `model_check`, the
   corpus and every projection are unchanged.
5. **Hecks gates the contract, not the reader's internals.** The gate runs the conformance corpus
   against the pinned reader. A contract change bumps the version on both sides.
6. **The phrase table stays in the `Sentence` chapter.** Adding a phrase is still a row edit here;
   the reader consumes the generated JSON and carries no grammar of its own.

## Consequences

- The reader's output is text a person can read and diff, which is also what the reader's tests
  compare against.
- The reader needs no hecks IR code, so nothing in `rust/parser` that serves the IR (`ir.rs`,
  `emit.rs`, the IR-facing parts of `build/`) has to be copied.
- Formatting (bluebook back to sentences) reads Ruby-form bluebook, not sentences, so it is not
  part of the reader's contract. It stays with the parser that reads bluebook until a decision
  moves it (see Not decided).
- `rust/parser` leaves this repository for the sentence reader only. The Ruby-form parser stays
  here, since hecks still reads `.world`, `.adapter` and `.hecksagon` files with it.
- The parity spec (`spec/parser_parity_spec.rb`) becomes a conformance run against the pinned
  reader, so it needs the reader's binary in CI.

## Not decided here

- Where the bluebook formatter lives after the split (hecks, or the reader as a second direction
  of the contract).
- How the reader binary reaches users who do not build from source (`PrebuiltBinary` or a release
  asset).
- Whether the phrase table is published as a standalone package.

Each of these is a follow-up ADR when the first reader release is cut.
