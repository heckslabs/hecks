# Shredding is a request the key vault answers

**Status:** Proposed. Not built. Date: 2026-10-27.

## Context

`Privacy::SubjectKey` records one subject's encryption key. Its `Shred` command, role
"Privacy officer", moves the record from `active` to `shredded` and emits `SubjectKeyShredded`.
The bluebook says so itself: `Shred` "records the destruction, never performs it".

The destruction is a call to the `key_vault` port. The order, destroy first and record second,
is kept in one place, `Ports::KeyVault.shred!` in Ruby. Nothing in the bluebook keeps it:

- `Shred` can be dispatched directly by any caller holding the role. The record then reads
  `shredded` while the key is still live and its ciphertext still readable. That is the
  opposite of what the event claims.
- `Issue` takes a `key_reference` as a plain string. Nothing ties it to a key the vault holds.
- The shape of the rule, "a key is shredded only after the vault destroyed it", is a fact about
  the domain, and it lives in an adapter-side helper. The fuzzer, the Rust host and a reader of
  the glossary cannot see it.

The language already has the right construct. A policy `ask`s for something the domain cannot
do itself, the hecksagon maps the port (ADR 0100), and `Bulk` uses it: `Request`, an ask the
runtime answers, then a system-only `Record`.

## Decision

1. **`Shred` becomes the request.** It keeps the role "Privacy officer" and the contract name
   `shred`, moves `active` to `shredding`, and emits `SubjectKeyShredRequested`. It no longer
   claims the key is gone.
2. **A policy asks the vault.** `DestroyKeyWhenShredRequested` is `on SubjectKeyShredRequested`
   and `ask :destroy_key, with: { key_reference: :key_reference }`. The hecksagon maps that ask
   to the `key_vault` port's `destroy`, so the bluebook names no adapter.
3. **A system-only command records the answer.** `MarkShredded`, role "System", moves
   `shredding` to `shredded` and emits `SubjectKeyShredded`, the event it emits today, now only
   after the vault answered. A policy on the answered event triggers it. A refused or failed
   destroy leaves the record in `shredding`, marked as a failure state, and the key is not
   reported gone.
4. **`Ports::KeyVault.shred!` shrinks to a dispatch of `Shred`.** The ordering it enforced is
   now the model's.
5. **Issuing a key may be asked the same way later.** `Issue` could `ask :issue_key` and take
   its `key_reference` from the vault's answer. Out of scope for the first slice.

## Alternatives considered

- **Leave the order in `shred!`.** It is what ships. Rejected: it is the rule outside the model.
- **A `given` on `Shred` that checks the vault.** The expression language cannot call a port,
  and ADR 0081's port-answered facts (`needs`) are not built.
- **Restrict `Shred` to "System" and let a Ruby helper check the officer's role.** It moves the
  authorization decision into Ruby, the wrong way.

## Consequences

- **A shape change.** The `SubjectKey` lifecycle gains `shredding`, and the chapter gains a
  command, an event and two policies. Existing rows (`active`, `shredded`) stay valid, but the
  chapter needs a translation edge and the shape ledger will move. Run `check_shape_ledger!`
  and rehearse the era before minting it.
- **The contract verb changes meaning.** `shred` in `provides "subject_keys"` now names a
  request, not a record. Any caller that destroys the key itself and then dispatches `shred`
  would destroy twice. In this repository only `Ports::KeyVault.shred!` does that; callers in
  other repositories were not searched.
- **Rust parity.** The host and kernel read Privacy by literal names (ADR 0025, update
  2026-09-14), and `spec/corpus/privacy.json` pins `Issue` then `Shred` end to end, so the
  fixture and the Rust side move with it.
- **Failure semantics need a decision before building.** What does a privacy officer see when
  the vault refuses, and may they retry from `shredding`? The sketch above leaves the record in
  `shredding` and allows no retry command.
- **The in-process vault is not durable** (its own comment says so). The ask changes nothing
  about that; a KMS adapter is the real answer to destruction surviving a restart.
