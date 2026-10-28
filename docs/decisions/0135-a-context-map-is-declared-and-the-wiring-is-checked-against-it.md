# A context map is declared, and the wiring is checked against it

**Status:** Built, with the kinds as builder-checked symbols rather than keyword rows (see Consequences).
Date: 2026-10-27. An `attaches` is an implied conformist relationship that a map need not write
(ADR 0155).

## Context

`Projections::ContextRelationships` already reads a context map off a registry. An
`attaches` becomes a shared kernel, a policy with `across` becomes customer/supplier, a
hecksagon `translates` becomes the anti-corruption layer, and a bare `subscribe` becomes
a listener. `ModelCheck::ContextChecks` then reports an unacknowledged `translates`
source and a cycle among the coupled contexts.

An attached member such as Governance is a context in its own right, with its own
language. Calling its `attaches` a shared kernel claims the two sides co-own a model,
which the wiring cannot know and which is usually false: the attaching context takes the
attached one's model as it is.

Every edge in that map is a consequence of code someone wrote. Nothing states the
relationship first, so nothing can say a coupling was a mistake. A developer who adds a
`subscribe` to a neighbour's internal event creates a dependency the review never sees,
and the map afterwards reports it as if it had been designed. A context map in the sense
Evans uses it is a decision the teams make before the wiring, and the wiring is held to
it.

Smaller gaps follow from the same cause:

- The relationship kinds the projection can derive are the ones the wiring can express.
  Conformist, open host service with a published language, partnership and separate ways
  have no source in the wiring, so they cannot be derived and cannot be checked.
- A `subscribe` or `translates` names any event of the supplier. There is no way to say
  which events a context publishes to its neighbours and which are its own business.

## Decision

1. **A system may declare a context map**, a `.contextmap` file beside the bluebooks it
   covers. It names each context with its owning team, and each relationship between two
   contexts:

   ```ruby skip
   Hecks.context_map "Shop" do
     context "Ordering",   team: "storefront"
     context "Billing",    team: "payments"
     context "Governance", team: "platform"

     relate "Billing" => "Ordering", as: :customer_supplier,
            published: %w[Billing.InvoicePaid Billing.PaymentFailed]
     relate "Governance" => "Ordering", as: :conformist
     separate_ways "Shipping", "Billing"
   end
   ```

   An edge reads `supplier => consumer`: the arrow points from the context depended on to
   the one that depends, so `ContextRelationships` edges, which point from dependent to
   dependency, are compared after reversing.
2. **The kinds are a closed set**: `customer_supplier`, `conformist`,
   `anticorruption_layer`, `shared_kernel`, `open_host`, `partnership`, and
   `separate_ways` (the last is its own word, not an `as:` kind). The builder checks the
   kind when the file loads.
3. **`model_check` compares the declared map with the derived one** and reports:

   | Finding | Meaning | Severity |
   | --- | --- | --- |
   | `:undeclared_coupling` | the wiring couples two contexts the map does not relate | error |
   | `:unused_relationship` | the map relates two contexts the wiring never couples | warning |
   | `:relationship_kind_mismatch` | the wiring implements another kind than declared | error |
   | `:unpublished_dependency` | a consumer reacts to a supplier event not in `published:` | error |
   | `:separate_ways_violated` | any edge between contexts declared `separate_ways` | error |
   | `:conformist_translates` | a `translates` on the consuming side of a `conformist` edge | warning |

   Derived kinds map as before. A `translates` implements `anticorruption_layer`, an
   `across` policy implements `customer_supplier`, an `attaches` implements `conformist`
   (the attaching context takes the attached one's model as it is), and a bare `subscribe`
   implements `conformist` too. The map may declare another kind for any pair, and
   `shared_kernel` is only ever declared, never derived, since the wiring cannot tell a
   model co-owned by two teams from one taken as given.
4. **`published:` is the published language.** On a `customer_supplier` or `open_host`
   edge it lists the supplier events a consumer may depend on. An event not listed is the
   supplier's internal event: it can change without notice, and a consumer reacting to it
   is reported.
5. **A shared kernel names what it shares.** `of:` lists the aggregates or value objects
   the two contexts hold in common. A context that uses another name from the other's
   side of a `shared_kernel` edge is reported as a leak.
6. **A context with no declared map is checked as today.** The declared map is optional.
   A system adopts it by writing the file, and from then on every coupling must appear in
   it. This keeps the command surface and every existing domain unchanged.
7. **The map is readable.** `hecks query context_map` renders the declared and derived
   edges together, one line per pair, marking which side each came from. The glossary
   generator groups each context's terms under its declared team.
8. **The map is drawn in the standard notation.** The same query renders a Mermaid
   flowchart, the form the generated glossaries already use for lifecycles. Each context is
   a node labelled with its team, and each relationship is an edge from the upstream
   context to the downstream one, with the end marks of Evans's context map: `U` on the
   upstream end and `D` on the downstream end; `OHS` and `PL` on the upstream end of an
   open host service with a published language; `ACL` or `CF` on the downstream end of an
   anticorruption layer or a conformist; `S` and `C` on the ends of a customer/supplier
   pair. A `shared_kernel` is an undirected edge marked `SK`, a `partnership` one marked
   `P`, and `separate_ways` is drawn as no edge, with the pair listed beside the diagram as
   declared apart. An edge the wiring implements but the map does not declare is drawn
   dashed and red,
   so a reviewer sees the undeclared coupling on the picture before the finding is read.
   An edge the map declares and the wiring never uses is drawn grey. The diagram is
   generated from the map and the derived edges, so it cannot drift from either.

## Alternatives considered

- **Keep deriving the map and add the missing kinds to the wiring.** It would give every
  kind a source, but a map written from the code can never refuse the code. Rejected: the
  point is a decision that comes first.
- **A `relationship:` option on `attaches`, `subscribe` and `translates`.** The kind would
  sit beside each coupling. It scatters the map over every hecksagon, so the whole system
  cannot be read in one place and a missing relationship is invisible. Rejected: one idea,
  one place (ADR 0025).
- **Make the declared map mandatory.** It would close the gap for existing domains at
  once, and fail every one of them that has not written a map. Not built: adoption should
  be the system's choice, and the warning-level findings should first show how often the
  derived map disagrees with intent.
- **Enforce published events on the supplier instead.** A supplier-side `publishes`
  declaration would work without a map. It cannot say who may depend on the events, and
  it leaves the consumer relationship undeclared. The map's `published:` covers it with
  the relationship attached.

## Consequences

- A coupling added without a decision fails `model_check` and must be recorded in the
  map, where its kind and direction are reviewed.
- The relationship kinds the derived map cannot express become declarable, and the
  `published:` list gives suppliers a contract they can change safely on the other side.
- `ContextChecks` gains the findings above and `ContextRelationships` gains a comparison.
  Neither changes what a bluebook means at run time, so the Rust kernel is unaffected;
  the Rust parser table gains the new keywords through `project_parser_table!`.
- `.contextmap` is a new file kind, so ADR 0134's list of what a bluebook is made of
  gains it, and the sentence form (ADR 0131) needs a plain-sentence spelling before the
  map is offered to business readers.
- **Built so far, over plain data:** `Bluebook::ContextMap` holds the contexts, their teams,
  the relationships and the separate-ways pairs; `ModelCheck::ContextMapChecks` reports
  `:undeclared_coupling`, `:unused_relationship`, `:relationship_kind_mismatch`,
  `:unpublished_dependency`, `:separate_ways_violated` and `:conformist_translates` against
  `ContextRelationships`' edges; `Projections::ContextMapDiagram` draws the Mermaid form.
  `ContextRelationships` still labels an attach `shared_kernel`, and the checks accept that
  edge as a `conformist`, a declared `shared_kernel` or an `open_host`.
- **The file kind, built:** `Hecks.context_map` is a top-level word (`*.contextmap` is the last
  glob of the `LoadOrder` vocabulary row), `DSL::ContextMapBuilder` turns the block into the
  `ContextMap` above, and a boot registers it (`Registry#context_map`). The language declares
  the words in `lib/hecks/language/context_map/context_map.bluebook` (`context_map`,
  `context`, `relate`, `separate_ways`), and `project_parser_table!` carries them to the Rust
  parser's table. `model_check` runs `context_map_findings` for every booted system that
  declares a map, in its `contexts` section; the `Introspection.context_map` query
  (`hecks query Introspection.context_map domain.value=<dir>`) answers the Mermaid diagram
  with each finding as a comment. Banking's map is `examples/banking/bluebook/banking.contextmap`.
- **The kinds are not keyword rows.** `as:` takes a symbol that the builder checks against
  `ContextMap::KINDS`, so a typo is refused when the file loads. Making each kind a row
  admitted through `propose!` and `admit!` would let a project add a kind without touching Ruby,
  but no check reads a kind the table does not already name, so the rows would carry nothing.
- **Not verified or not built:** the Rust side only parses the new words; no Rust code reads a
  context map, and `cargo test` of the parser was not run in this change. A `published:` check
  holds only for subscriptions, which name the event they depend on; a policy edge names a
  policy, which has no event to hold to the list. The sentence form (ADR 0131) has no spelling
  for a map.
- Open: whether a context's team belongs in the map or in each context's own
  declaration, and whether `partnership` needs a pair of `published:` lists.
- Not decided here: a subdomain kind (core, supporting, generic) per context. No check
  would read it yet, and a word earns its place by being used (ADR 0026); it joins the
  map when a check keys on it.
