# The two Translation chapters become one

**Status:** Proposed. Date: 2026-09-28. Split out of [ADR 0080](0080-bin-scripts-become-adapters-on-a-hecks-bluebook.md), which attaches chapters by name and so cannot attach two chapters that share one. Nothing below is built yet.

## Context

Two chapters are named Translation, and they are two halves of one concept:

- `lib/hecks/grammar/translation.bluebook` is the register of rule kinds. A `Rule` moves from proposed to admitted to retired and must execute in at least two targets before it is admitted. Its `Map` aggregate is an edge between two eras.
- `lib/hecks/language/translation/` is the meta-model of one `translations/*.bluebook` edge file: the `Translation` aggregate (domain, from era, to era) and `TranslationAggregate` with its typed rule lists. `MetaValidator` loads it into the shared grammar registry, and `TranslationJudge` dispatches to it.

They overlap. `Rule.Kind` repeats the language chapter's rule words, held equal only by `spec/translation_vocabulary_conformance_spec.rb`, and `Map` duplicates the `Translation` aggregate. They have never shared a registry: `Hecks::Grammar.grammar_chapters` loads the grammar chapter alone. That separation is the only reason the shared name works today.

## Decision

They become one chapter, spread over files the way `lib/hecks/language/bluebook/` is:

- `grammar/translation.bluebook` moves to `lib/hecks/language/translation/rule.bluebook` and keeps opening `Hecks.bluebook "Translation"`.
- `Map` folds into `Translation` and `TranslationAggregate`, so an edge has one aggregate.
- `Rule` is where rule kinds are declared. The language chapter's rule words read from it, so the conformance spec that holds two lists equal is no longer needed.
- The `Translation` block in `lib/hecks/grammar/grammar.hecksagon` goes; the merged chapter is wired where the language chapter already is.

## Consequences

- `Hecks::Grammar.grammar_chapters`, and the globs in `lib/hecks/codemod.rb` and `lib/hecks/corpus.rb`, point at the new file.
- `spec/parser_parity_spec.rb` parses Translation as a chapter of several files.
- The corpus replay `spec/corpus/translation.json` loses its `Translation::Map.*` verbs in favour of the edge aggregate's.
- SyntaxBoot's disk cache is keyed over every chapter in the shared registry, so the merge invalidates it once.
- No data moves: the grammar chapter persists to Memory and keeps no records, and neither chapter has an IR golden.
- `Translation::Map` is removed, which is a breaking change; it ships in a major version.

## Alternatives considered

- **Renaming the grammar chapter to `TranslationGrammar`.** A few lines of change. Rejected: it keeps two lists of rule kinds and two edge aggregates, held together by a spec instead of by the model.
- **Leaving both as they are.** Workable only while the grammar chapter never shares a registry with the language chapter. Rejected as the long-term state, since ADR 0080 attaches chapters to one domain by name.
