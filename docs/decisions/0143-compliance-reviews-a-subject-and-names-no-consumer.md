# Compliance reviews a subject, and names no consumer

**Status:** Proposed. Not built. Date: 2026-10-27.

## Context

`Compliance` ships in the gem as a framework bluebook, yet its model is its customers' vocabulary:

- `AccountFreezeReview` and `BoxSurrenderReview` are Banking's facts. Each `Open` command
  "takes exactly the fields" of one Banking event (`AccountFrozen` carries `number`,
  `BoxSurrendered` carries `branch_code` and `box_number`), and the file says so.
- `PrivacyReview` takes `domain` and `attribute_path`, the identity of Privacy's `Marking`.
- Each source costs Compliance a new aggregate, three commands, three events and three OIDC
  scopes. A fourth source means editing the framework chapter.

The relationship is a customer/supplier one with the roles inverted. Compliance supplies
a service, but the customer decides the supplier's language. In context-map terms Compliance
conforms to Banking and Privacy instead of publishing a language of its own.

Banking's side is visible in the wiring: two policies `across "Compliance"` whose targets are
named `AccountFreezeReview.Open` and `BoxSurrenderReview.Open`, and a `subscribe` to
`Compliance.AccountFreezeReviewOpened`. That relationship is now pinned by
`spec/context_map_banking_spec.rb` as a declared customer/supplier edge, so the coupling is
deliberate and checked. This ADR is about its shape.

## Decision

1. **One aggregate, `Review`, identified by what is reviewed.** Its identity is a subject
   kind and a subject key, both text: `account_freeze` and `A-1`, `box_surrender` and
   `BR1:42`, `privacy_marking` and `attendee.medications`. It keeps the lifecycle
   `open` to `cleared` or `escalated`, and the commands `Open` (role "System"), `Clear` and
   `Escalate` (role "Compliance officer").
2. **The consumer maps its fact to a subject.** Each consuming policy names the kind and the
   key in its `with:`, which is where the translation belongs: in the context that knows its
   own events. Compliance learns no consumer's field names.
3. **A new source adds a policy, not a chapter edit.** Banking, Privacy, or a client's own
   domain starts a review by naming a kind of its own choosing.
4. **Events are `ReviewOpened`, `ReviewCleared` and `ReviewEscalated`,** each carrying the
   subject, so a consumer subscribes to the one published language.

## Alternatives considered

- **Keep one aggregate per source.** It is what ships, and it keeps each event's fields typed.
  Rejected: the typing is Banking's, bought at the price of the supplier's generality.
- **A shared kernel of the event shapes.** It would make the coupling explicit and shared.
  Rejected: Compliance would still change whenever a customer's event does.
- **An anticorruption layer in Compliance that reads each source.** It would put the
  translation in the supplier, so the supplier still names every customer.

## Consequences

- **A wide, breaking change, not built here.** It touches:
  - the Compliance bluebook and the `examples/compliance` link, and its OIDC scopes;
  - Banking's two policies and its `subscribe`, and the Privacy wiring that reaches
    `PrivacyReview`;
  - the Rust host's tests that name `Compliance::AccountFreezeReview.Open`, and the
    conformance fixtures whose reaction logs contain it verbatim, which can only be
    re-verified against a Rust build;
  - `spec/corpus/compliance.json`, Banking's golden IR, the generated glossary and diagrams,
    and the reference pages that quote the old names.
- **A shape change.** The chapter loses three aggregates and gains one, so it needs a
  translation edge and a rehearsed era. Whether any deployed store holds review rows was not
  checked.
- **A composite key needs a decision.** A box has two identity fields. The `with:` must join
  them into one key, and the policy language may not be able to compute that without a new
  word. Check this before building.
- **Subject kinds become a convention.** Nothing declares the set of kinds; a typo opens a
  review nobody expects. A closed set per deployment, or a `published:` list in the context
  map, are the two ways to check it.
