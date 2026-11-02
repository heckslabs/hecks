# A bluebook's classification keys the dependency checks

**Status:** Accepted (owner, 2026-11-02). Date: 2026-11-02. Adds two model_check findings and no grammar word.

## Context

A bluebook may say `core`, `supporting` or `generic`. The builder records it
(`lib/hecks/bluebook/dsl/bluebook_builder/metadata.rb`), the language validates it
(`lib/hecks/language/bluebook/bluebook.bluebook`, value object `Classification`: "a bluebook is core,
supporting, or generic"), and the IR carries it. Only prose and the sentence form read it:
`narrate_projector.rb` writes "This is a core domain.", `docs_projector.rb` prints it, and
`sentence.bluebook` round-trips "This is a {kind:word} domain". No check reads it. Under `lib` the corpus
holds 6 core, 10 supporting and 4 generic bluebooks.

No ADR introduced the word. ADR 0135 deferred it on purpose: "Not decided here: a subdomain kind (core,
supporting, generic) per context. No check would read it yet, and a word earns its place by being used
(ADR 0026 [sic: ADR 0025]); it joins the map when a check keys on it."

The builder's own comments give the words a narrower sense than Evans's: `core` is "core to the
framework, rather than a domain built on it", `supporting` "a supporting piece of the framework",
`generic` "generic infrastructure". That reads as membership in Hecks, not as the kind of subdomain.
The two senses agree for Hecks's own bluebooks, and for a user's domain only the subdomain sense makes
sense: a user's billing context is not "core to the framework".

## Decision

1. **The words mean the subdomain kind.** `core` is where the domain's advantage lies, `supporting` is
   specific to this business but not its advantage, `generic` is a solved problem that could be bought or
   attached. The builder's comments are reworded to say so; for Hecks's own bluebooks the meaning does not
   change.
2. **model_check reads each context's classification from its bluebook.** The `.contextmap` does not
   restate it: one idea, one spelling (ADR 0025), and the bluebook already holds it.
3. **`generic_depends_on_core` (error).** An edge from a generic context to a core one, as
   `Projections::ContextRelationships` derives it from the wiring. A generic subdomain that depends on the
   core cannot be replaced or bought, which is the reason to call it generic. The fix is to invert the
   dependency (the core publishes, the generic context does not reach in) or to reclassify. It is
   computed from the edges and each bluebook's classification and runs without a `.contextmap`; it is not
   part of `context_map_findings`, which returns nothing when there is no map.
4. **`core_conforms` (warning).** A relationship declared `conformist` in a `.contextmap` whose
   downstream context is core. The core model should translate what it receives (an anti-corruption
   layer), not adopt another context's model. It is checked against declared relationships only: the
   conformist that ADR 0155 implies for each `attaches` is added when the map is read and has nowhere to
   carry an acknowledgement, and core grammar contexts attach Governance and others by design.
5. **`core_conforms` can be acknowledged.** It joins the closed list of relationship findings in ADR 0150
   item 2, as ADR 0155 item 5 extended it (`relationship_kind_mismatch`, `conformist_translates`,
   `unpublished_dependency`, `unused_relationship`, `redundant_relationship`), and
   `Acknowledgements::RELATIONSHIP_KINDS` gains it, so a core context that conforms on purpose says why
   on the relationship. It is part of `context_map_findings`, since it reads declared relationships.
   `generic_depends_on_core` cannot be acknowledged, as an undeclared coupling cannot: the fix is in the
   wiring or the classification.

## Consequences

- The classification earns its place as ADR 0135 asked: two checks key on it.
- A bluebook that declares no classification is not checked by either finding.
- `core_conforms` sits beside `conformist_translates` (ADR 0135), which catches the opposite mistake: a
  relationship declared conformist that translates anyway.
- Before landing the checks, model_check is run over the corpus. Any finding on Hecks's own bluebooks is
  either a real dependency to invert or a classification to correct, and each is settled in the same
  change.
- ADR 0164's "core" means the packaging line around the language spec, not this subdomain kind. 0164 is
  still Proposed, and is worth rewording (for example "the spec core") so a reader does not meet one word
  with two meanings.

## Alternatives considered

- **Declare the kind per context in the `.contextmap`.** Rejected: it would restate what the bluebook
  says, and two maps could disagree with it.
- **Suggest attaching a package for a generic bluebook written by hand.** Out of scope: Hecks has no
  catalogue of packages to suggest from, so no check could say which.
- **Fire `core_conforms` on implied attach relationships too.** Rejected: every core grammar context would
  warn, with no place to acknowledge it.
