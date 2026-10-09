# An ask in flight is recorded by the runtime, not modelled in the domain

**Status:** Proposed. Nothing is built. Date: 2026-10-09. It is decision 6 of [ADR 0100](0100-policies-ask-and-the-hecksagon-maps-the-port.md), taken out so that ADR could land: once the runtime knows an `ask` is outstanding, the run protocol a chapter models by hand can shrink.

## Context

`docs/plans/3.0/FOLLOWUP-domain-leaks.md` items 2 and 3. A chapter that reaches the outside models the protocol itself: a `requested` lifecycle, an accept command and an abandon command that only record that an ask was made and came back, `Report` and `Output` value objects holding raw subprocess text, and a `RunKey` the caller names. The 2026-10-09 audit counts 36 lifecycles starting in `requested` and 34 `Report` value objects, and each new chapter copies the shape.

## Proposal

1. DOMAIN: an aggregate declares what an ask settles into, for example `asks_for :check, answers: "Pass", refuses: "Flag"`, and the runtime moves the record. The `requested` state, the accept command and the abandon command stop being modelled. Whether this is lifecycle sugar or a new word is the decision this ADR makes.
2. DOMAIN: raw subprocess text becomes one opaque `evidence` attribute the domain stores without parsing; the typed parts (checked, failed) stay.
3. HECKSAGON: the run key and the attempt identity move to the ask, minted by the runtime, so `RunKey` leaves the domain.

## Open items

- Sugar over `lifecycle` or a new word.
- How a chapter that already models the protocol migrates without changing what its callers see.
- Whether `evidence` is a language type or a convention.
