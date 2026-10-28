# A subject's key is issued by the vault's answer

**Status:** Accepted and built. Date: 2026-10-28. Follows [0142](0142-shredding-is-a-request-the-key-vault-answers.md), which did the same for destruction.

## Context

ADR 0142 made a shred a request the key vault answers, so a `SubjectKey` reads `shredded` only
after the vault destroyed the key. Issuing was still the older shape. A caller asked the vault for a
key (`Ports::KeyVault.issue`), received an opaque `key_reference`, and dispatched
`Privacy::SubjectKey.Issue` with that string as an argument. Nothing in the bluebook tied the
reference to a key the vault held: `Issue` recorded any non-empty string, so a record could claim a
key that existed nowhere.

## Decision

1. **`Issue` takes the subject and no reference.** It leaves the record `issuing` and emits
   `SubjectKeyIssueRequested`. `key_reference` is optional until the vault answers. A caller that
   still passes one is refused as an unknown argument; two ways to say one thing would leave the
   unchecked one open (ADR 0025).
2. **A policy asks the vault.** `IssueTheKeyWhenAsked` is `on SubjectKeyIssueRequested` and
   `ask :issue`. The `Keys` port gains an `Issue` operation that answers `SubjectKeyIssued` with the
   reference, or refuses `SubjectKeyIssueRefused`.
3. **System-only commands record the answer.** `RecordKey` (policy `RecordTheKey`) moves `issuing`
   to `active` and sets `key_reference`. `FailIssue` (policy `RecordTheIssueRefusal`) moves
   `issuing` to `issue_failed` and keeps the reason in `refusal`. `Reissue` moves `issue_failed`
   back to `issuing` and emits `SubjectKeyIssueRetried`, which `IssueTheKeyAgain` also answers by
   asking the vault. It has its own event because one event is one fact with one shape.
4. **One adapter binds both operations.** `KeyDestroyer` is renamed `KeyKeeper` and gains `issue`;
   `privacy.key_keeper.adapter` binds the `Keys` port. `Ports::KeyVault.issue` stays the vault
   operation that returns a reference. It is the adapter's call now, so nothing that holds the vault
   port changes.

## Consequences

- A record can no longer name a key the vault does not hold. `active` means the vault issued it.
- Every dispatcher of `Issue` changes with it. In this repository that is the `privacy-parity`
  corpus script and `spec/privacy_shred_spec.rb`; the corpus now ends on six events. Dispatchers in
  other repositories were not searched.
- The lifecycle gains `issuing` (now the default), `issue_failed` and the `Reissue` edge. Framework
  members are not in the shape ledger, so no translation edge exists for the move. A store that
  already holds `SubjectKey` rows keeps them as `active` or `shredded`, but a row written before
  this change has `status` `active` by the old default and stays valid; no stored row is rewritten.
  A deployed store was not checked.
- `SubjectKeyIssued` now means the vault's answer, after the request and with the reference in its
  payload. A consumer that reacted to the old event sees it later.
- The OIDC manifest for Privacy gains scopes for `RecordKey`, `FailIssue` and `Reissue`.
