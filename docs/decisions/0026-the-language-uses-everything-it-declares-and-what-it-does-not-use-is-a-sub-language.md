# The language uses everything it declares, and what it does not use is a sub-language

**Status:** Accepted — not yet implemented. Depends on ADR 0025's principle 4 (a word earns its place by being used) and on `MetaValidator.defer`, which landed in `97dfdf9` and made the language bootable as an ordinary domain in the first place.

## Context

`lib/hecks/language/bluebook/` declares what a bluebook IS. Until this week it could not be booted the way the bluebooks it describes are booted — nine files each say `Hecks.bluebook "Bluebook"`, and each was judged before its siblings had been read. `MetaValidator.defer` fixed that, and booting it made a second question askable for the first time: **does the language use the constructs it declares?**

Measured, counting real declarations rather than grammar rows:

| construct | language | banking |
|---|---|---|
| `value_object` | **100** | 47 |
| `aggregate` | **14** | 10 |
| `one_of` blocks | **23** | 3 |
| `admits:` | **20** | 2 |
| `list_of` | **25** | 6 |
| `lifecycle` / `transition` | **0 / 0** | 13 / 37 |
| `entity` | **0** | 4 |
| `policy` / `process_manager` | **0 / 0** | 6 / 3 |
| `ensures` | **0** | 3 |
| `limit` `offset` `cursor` `nulls` `authorize` `group_by` | **all 0** | 6/0/0/0/1/1 |

So the language is the richest domain in the repository for *shape* and uses none of the vocabulary for *behaviour over time*. That is not merely an omission, because in the two places the language genuinely has behaviour, it hand-rolled it:

**It has a state machine and modelled it as an attribute.** A word moves `proposed → admitted → deprecated → retired` (`syntax.bluebook:127-142`), declared as a `value_object "Status"` with a `one_of`, and read as `attribute :status, String, default: "admitted", admits: "Syntax::Status"`. Nothing refuses `proposed → retired` skipping `admitted`, or `retired → admitted` resurrecting a dead word. And `bin/model_check` reports *"Bluebook (the language itself) — clean — no dead states, no unreachable protocol steps"* — clean because the language declares **no states at all**, not because its state machine was checked. The checker the language ships cannot see the language's own state machine.

**It has owned pieces and modelled them as references.** Every containment in the language is a cross-aggregate reference:

```
Command -> aggregate_id    ValueObject -> aggregate_id    Member  -> value_object_id
Query   -> aggregate_id    Handler -> process_manager_id  Dispatch -> handler_id
```

A `Member` has no life outside its `ValueObject`; a `Dispatch` none outside its `Handler`. That is what `entity` is for, and `entity` is declared by the language and used zero times in it.

This is the same defect ADR 0025 catalogues throughout the DSL — a construct that exists, applies exactly here, and is not used — except here the domain declining to use it is the one that *defines* it.

## Decision

### The language uses everything the core grammar declares

A gate demands it, modelled directly on `spec/fuzzing/meta_domain_coverage_spec.rb`, which already reads `MetaValidator.grammar_registry` and requires every declared feature to be claimed, guaranteed by construction, structurally exempt, or a named gap carrying a one-line reason. The same shape, aimed at construct *usage in the language's own chapters*.

### What the language does not use is not core — it is a sub-language

The obvious way to make that gate survivable is an exemption list. This decision rejects that. Instead, **anything the core language does not use is demoted out of the core grammar into a sub-language**, with its own chapter, its own corpus, and its own use obligation.

That inverts the gate from something needing excuses into something that *defines the boundary*: the core language is exactly what the language itself uses, by construction rather than by assertion.

Sub-languages already exist and set the precedent — `lib/hecks/grammar/expression.bluebook` (*"the subset of regular Ruby a predicate is allowed to be"*) and `translation.bluebook` (*"the declared bridge from one era of a domain's storage shape to the next"*) are self-contained chapters describing one bounded concern each, standing apart from the core grammar. This decision names the pattern and gives it a seam.

### The sub-language declares where it attaches

`Paging` says it attaches to `Query` and `ReadModel`. The core grammar does not name its extension points, and adding a sub-language changes nothing in the core.

This is the additive choice, and additivity is the whole point: a sub-language that required editing the core grammar to attach would leave the core carrying a list of everything that might ever extend it — which is the same "declares what it does not use" defect this ADR exists to remove, one level up. A core that names `Paging` is a core that knows about paging.

**The objection, and why it is survivable.** Under this rule you cannot read `Query` in `syntax.bluebook` and know everything a `query` body admits; you must know which sub-languages are loaded. That is the "which file adds this?" problem, and it is real.

What makes it acceptable here is that **nobody reads the grammar to answer that question** — `bin/reference` generates `docs/implemented/reference/query.md` from the live grammar, and a generated page can enumerate the loaded sub-languages' contributions as easily as the core's. The authoritative answer to "what may appear in a query?" is a generated document either way, so the seam's direction changes where the *fact* lives without changing where the *answer* is read. The obligation this creates is on `bin/reference`: a sub-language's words must appear on the context page they attach to, marked as coming from that sub-language, or this trade is not paid for.

A related consequence, accepted: the set of legal words in a body becomes a function of what is loaded rather than a constant. Two projects loading different sub-languages accept different bluebooks. That is the intended behaviour — it is what makes a sub-language a language rather than a section — but it means a bluebook is only portable across projects that load the same sub-languages, and `uses_framework` is the existing precedent for declaring that kind of dependency explicitly.

### The first demotion, and the two remodels

- **`limit`, `offset`, `cursor`, `nulls` leave the core grammar for a `Paging` sub-language.** A grammar is enumerated, not scrolled; the core language will never page a query, and it should not declare vocabulary it will never use. `Paging` attaches itself to `Query` and `ReadModel`, and banking — which does page — exercises it.
- **`Status` becomes a real `lifecycle`** with declared transitions, so the ordering is enforced by declaration and the model checker can finally see it.
- **`Member`, `Dispatch`, and `Handler` become entities** of `ValueObject`, `Handler`, and `ProcessManager` respectively.

## Consequences

- **The model checker gains its own subject.** Once `Status` is a lifecycle, `bin/model_check`'s verdict on the language stops being vacuously clean.
- **The entity remodel is substantial, not cosmetic.** Making `Member` an entity of `ValueObject` moves those records inside the parent aggregate, and the meta-domain's readings and reconstruction machinery reads them as separate aggregates today. This is the largest single item here and should be sequenced last.
- **The self-use gate will fail on the day it is written**, and that is the point — `entity`, `lifecycle`, `transition`, `policy`, `ensures`, `provenance`, `group_by` and `authorize` are all declared and unused. Each is then either used, or demoted to a sub-language, and the gate records which.
- **`generic` is a candidate for demotion rather than adoption.** ADR 0025 lists it among the eleven words with no corpus use; a subdomain classification the language itself never applies is exactly what this decision demotes.
- **ADR 0025's principle 4 remains the general bar** — a word must be used by *some* domain. This gate is stricter and catches a different thing: it flagged `Status` and the `Member`/`Dispatch` containment, neither of which principle 4 would see, since banking uses `lifecycle` and `entity` heavily.

## Open, deliberately

- Whether `expression` and `translation` are retrofitted to the same seam mechanism. They attach differently today, and unifying them is not required for paging to move.
- Whether the self-use gate applies to each sub-language against its own corpus, or only to the core. A `Paging` sub-language used by banking and not by the language is fine; the question is what the rule *says* rather than what happens to be true.

## Rejected alternatives

- **The core declaring its own seams** (`Query` admits `Paging`). Rejected because it puts a list of possible extensions into the core grammar — a core that names `Paging` knows about paging, which is the very thing being removed. Its advantage, that reading `Query` tells you what a query body admits, is answered instead by `bin/reference` rendering the loaded sub-languages onto the context page they attach to.
- **An exemption list on the core gate.** This was the first design and it is worse: it makes "the language does not use this" a permanent, defensible state, when the honest reading is that such a construct was never core. Demotion says the same thing and leaves the core coherent.
- **Forcing every construct into the language.** Paging a grammar, authorising a read of a grammar, and grouping words by context are decoration of exactly the kind ADR 0025 argues against elsewhere — modelling to satisfy a tool. Demotion is what makes refusing this compatible with a total gate.
