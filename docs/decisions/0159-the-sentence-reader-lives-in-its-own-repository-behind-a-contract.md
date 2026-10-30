# The sentence reader lives in its own repository behind a contract

**Status:** Accepted.
Date: 2026-10-29.
Supersedes: 0131 §1 (the `.bluebook` extension is the only file kind) only in the part that places
the reader inside hecks; 0131 §5 (one reader, in Rust, inside this repository) and the
"not a separate language" clause of 0131 §1 are superseded by this decision.

## Context

ADR 0131 let a `.bluebook` be written as plain sentences and kept the whole reader in this
repository: the grammar lives in the `Sentence` chapter, `rust/parser` is generated from it, and
`hecks-parse`, the formatter, `complete` and `hecks-lsp` are built beside the domain.

Two things have become clear since then. The reader's concerns (lexing, phrase matching,
diagnostics, editor support, the formatter) change on a different rhythm from the domain. Those
concerns are also the part another team could reasonably own or reuse. What the rest of hecks
actually depends on is much smaller: the IR, and the mapping from sentences to that IR.

## Decision

1. **Hecks owns the contract, not the reader.** The contract is the set of artifacts that any
   sentence reader must honour:
   - the **IR** shape (`ir.json`), as the Ruby runtime defines it;
   - the **phrase table** (`contract/phrases.json`), projected from the `Sentence` chapter,
     with one row per phrase: `id`, `context`, `pattern`, `opens`, `status`;
   - the **mapping rules** (sentence to IR), written in `docs/sentence-contract.md`;
   - the **conformance corpus**: sentence files and the IR each must lower to, under
     `spec/fixtures/sentence/`.
2. **The reader lives in its own repository** (working name `hecks-sentence`). It holds the
   lexer, the parser, the formatter, `complete`, the diagnostics and `hecks-lsp`. It depends on
   a pinned contract version, not on hecks' source tree.
3. **Hecks keeps lowering and loading.** `Hecks::SentenceForm` and `Adapters::Folder#load_file`
   stay here. They call the reader's binary, take the IR it returns, and boot as before. Nothing
   downstream of the IR changes.
4. **Hecks gates the contract, not the reader's internals.** The hecks gate runs the conformance
   corpus against the reader at the pinned version. A contract change needs a version bump on
   both sides, and the reader's own tests cover its internals.
5. **The phrase table is the contract's source of truth and stays in the `Sentence` chapter.**
   Adding a phrase is still a row edit here. The reader consumes the generated JSON; it never
   carries its own copy of the grammar.

## Consequences

- The reader can ship, version and be reused on its own schedule. A second reader that passes the
  corpus is a valid implementation.
- `rust/parser` leaves this repository. Its specs and the `IO_PARALLEL_EXCLUDE_PATTERN` entries
  for them move or become a pinned-binary check. `PrebuiltBinary` gains a row for the reader.
- The parity spec (`spec/parser_parity_spec.rb`) becomes a conformance run against the pinned
  reader, so it needs the reader's binary in CI.
- Ownership of the reader's release is a separate question from this ADR. Until it is decided,
  the reader is built from the pinned revision in the gate, and nothing is published.

## Not decided here

- The reader repository's name and visibility.
- How the binary reaches users who do not build from source (`PrebuiltBinary` or a release asset).
- Whether the phrase table is also published as a standalone package.

Each of these is a follow-up ADR when the first reader release is cut.
