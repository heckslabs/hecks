# A subject's key is issued by the vault's answer

**Status:** Proposed. Not built. Date: 2026-10-28. Follows [0142](0142-shredding-is-a-request-the-key-vault-answers.md), which left this open.

## Context

ADR 0142 made a shred a request the key vault answers, so a `SubjectKey` reads `shredded` only
after the vault destroyed the key. Issuing is still the older shape. A caller asks the vault for a
key (`Ports::KeyVault.issue`), receives an opaque `key_reference`, and dispatches
`Privacy::SubjectKey.Issue` with that string as an argument. Nothing in the bluebook ties the
reference to a key the vault holds: `Issue` records any non-empty string.

That is the other half of the rule 0142 closed for destruction. A record can claim a key that
exists nowhere, and the destruction later asked of it would find nothing to destroy.

## Decision (proposed)

1. **`Issue` takes the subject and no reference.** It moves the record to `issuing` and emits
   `SubjectKeyIssueRequested`; the `key_reference` attribute is optional until the vault answers.
2. **A policy asks the vault.** `IssueTheKeyWhenAsked` is `on SubjectKeyIssueRequested` and
   `ask :issue`. The `Keys` port gains an `Issue` operation that answers `SubjectKeyIssued` with
   the reference, or refuses `SubjectKeyIssueRefused`. `KeyDestroyer` becomes the adapter for both
   operations, or a second adapter binds the same port.
3. **System-only commands record the answer.** `RecordKey` moves `issuing` to `active` and sets
   `key_reference`; `FailIssue` moves `issuing` to `issue_failed`. A privacy officer may ask to
   issue again from `issue_failed`.
4. **`Ports::KeyVault.issue` stays a vault operation** that returns a reference. It is the
   adapter's call, no longer the caller's, so nothing that holds the vault port changes.

## Why it is not built

The change is breaking for every dispatcher of `Issue`, and offering the old and new forms side by
side would be two ways to say one thing (ADR 0025).

- **The command's arguments change.** A caller that passes `key_reference` is refused as an unknown
  argument. In this repository that is `spec/corpus/privacy.json`, `spec/privacy_shred_spec.rb` and
  `Ports::KeyVault`'s own doc. Callers in other repositories were not searched.
- **The lifecycle gains states** (`issuing`, `issue_failed`), so rows in an existing store stay
  valid but the chapter's shape moves. Framework members are not in the shape ledger, so no
  translation edge would be written, and a deployed store was not checked.
- **The event's meaning shifts.** `SubjectKeyIssued` is today's `Issue` event and would become the
  vault's answer. A consumer that reacts to it would see it later, after the request, with the
  reference in the payload.

## Alternatives considered

- **Keep both forms.** `Issue` with a reference and a new `RequestKey` that asks the vault. Rejected
  for the reason above: two ways to say one thing, and the unchecked one stays open.
- **Check the reference against the vault inside `Issue`.** The expression language cannot call a
  port, and ADR 0081's port-answered facts (`needs`) are not built.

## Consequences if accepted

- A record can no longer name a key the vault does not hold.
- Every dispatcher of `Issue` changes in the same release; the corpus script, the specs and any
  consumer. That is the cost this proposal leaves for the owner to take.
