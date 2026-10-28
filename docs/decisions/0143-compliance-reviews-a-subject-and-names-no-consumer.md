# Compliance reviews a subject, and names no consumer

**Status:** Accepted. Built on this branch, not released. Date: 2026-10-27. Needs
[0149](0149-a-policy-reads-the-emitting-records-identity-as-id.md).

## Context

`Compliance` ships in the gem as a framework bluebook, yet its model was its customers'
vocabulary:

- `AccountFreezeReview` and `BoxSurrenderReview` were Banking's facts. Each `Open` command
  took exactly the fields of one Banking event (`AccountFrozen` carries `number`,
  `BoxSurrendered` carries `branch_code` and `box_number`), and the file said so.
- `PrivacyReview` took `domain` and `attribute_path`, the identity of Privacy's `Marking`.
- Each source cost Compliance a new aggregate, three commands, three events and three OIDC
  scopes. A fourth source meant editing the framework chapter.

The relationship was a customer/supplier one with the roles inverted. Compliance supplies a
service, but the customer decided the supplier's language. In context-map terms Compliance
conformed to Banking and Privacy instead of publishing a language of its own. That relationship
is pinned by `spec/context_map_banking_spec.rb` as a declared customer/supplier edge.

## Decision

1. **One aggregate, `Review`, identified by what is reviewed.** Its identity is a subject kind
   and a subject key, both text: `account_freeze` and `A-1`, `box_surrender` and `BR1:42`,
   `privacy_marking` and `Studio::Registration:attendee.medications`. It keeps the lifecycle
   `open` to `cleared` or `escalated`, and the commands `Open` (role "System"), `Clear` and
   `Escalate` (role "Compliance officer"). Its events are `ReviewOpened`, `ReviewCleared` and
   `ReviewEscalated`.
2. **The consumer maps its fact to a subject.** Each consuming policy names the kind as a
   literal and reads the key from the event's record as `:id` (ADR 0149):
   `trigger Review::Open, with: { subject_kind: "account_freeze", subject_key: :id }`. A
   composite identity arrives joined by a colon. The translation sits in the context that
   knows its own events, and Compliance learns no consumer's field names.
3. **A new source adds a policy, not a chapter edit.** Banking, Privacy, or a client's own
   domain starts a review by naming a kind of its own choosing.

## Alternatives considered

- **Keep one aggregate per source.** It keeps each event's fields typed. Rejected: the typing
  is Banking's, bought at the price of the supplier's generality.
- **A kind, a key and a numbered part.** Tried first, with no language change. A box's
  identity fits (a string and an integer), an account's does not need the part, and Privacy's
  marking (two strings) does not fit at all. Rejected for the policy reading `:id` instead.
- **A shared kernel of the event shapes.** Rejected: Compliance would still change whenever a
  customer's event does.
- **An anticorruption layer in Compliance that reads each source.** It would put the
  translation in the supplier, so the supplier would still name every customer.

## Consequences

- **A breaking change to the chapter.** `AccountFreezeReview`, `BoxSurrenderReview` and
  `PrivacyReview` are gone, and so are their events and OIDC scopes. Banking's two policies, the
  `subscribe` line, the Rust host's tests, the recorded reaction logs in the corpus, Banking's
  golden IR, the generated glossary and diagram, and the reference pages that quote the old
  names are all updated here.
- **A shape change.** The chapter loses three aggregates and gains one. Whether any deployed
  store holds review rows was not checked, and a translation edge for one was not written.
- **Subject kinds are a convention.** Nothing declares the set of kinds, so a typo opens a
  review nobody expects. A closed set per deployment, or a `published:` list in the context
  map, would check it.
- **Privacy is not wired.** The Privacy marking review had no consumer in this repository (its
  comment described a `translates` in a hecksagon that attaches both), so there is nothing to
  rewire; the corpus script now opens a `privacy_marking` review directly.
- **Rust.** Building this showed the Rust host ignored `with:` on a cross-domain policy, which
  would have sent Compliance the old arguments; ADR 0149 records the fix. The generated
  Compliance and Banking code regenerates, the kernel tests pass, and the host's cross-domain
  tests pass against a rebuilt `banking.wasm`, including the arguments it delivers. The
  conformance fixtures that record the refused reaction were renamed by hand and Ruby answers
  them as written; none were replayed against a Rust build of the generated host.
