# Shredding is a request the key vault answers

**Status:** Accepted. Built on this branch, not released. Date: 2026-10-27.

## Context

`Privacy::SubjectKey` records one subject's encryption key. Its `Shred` command, role
"Privacy officer", used to move the record from `active` to `shredded` and emit
`SubjectKeyShredded`. It recorded a destruction and never performed it, and the bluebook said so.

The destruction is a call to the `key_vault` port. The order, destroy first and record second,
was kept in one place, `Ports::KeyVault.shred!` in Ruby. Nothing in the bluebook kept it:

- `Shred` could be dispatched directly by any caller holding the role. The record then read
  `shredded` while the key was still live and its ciphertext still readable. That is the
  opposite of what the event claims.
- The rule, "a key is shredded only after the vault destroyed it", is a fact about the domain,
  and it lived in an adapter-side helper that the fuzzer, the Rust host and a reader of the
  glossary cannot see.

The language already has the right construct. A policy `ask`s for something the domain cannot do
itself, the hecksagon maps the port (ADR 0100), and `Bulk` uses it: `Request`, an ask the runtime
answers, then a system-only `Record`.

## Decision

1. **`Shred` is the request.** It keeps the role "Privacy officer" and the contract name `shred`,
   moves `active` or `shred_failed` to `shredding`, and emits `SubjectKeyShredRequested`. It no
   longer claims the key is gone.
2. **A policy asks the vault.** `DestroyTheKeyWhenAsked` is `on SubjectKeyShredRequested` and
   `ask :destroy`. The `Keys` port, declared in `privacy.ports.hecksagon`, answers
   `SubjectKeyDestroyed` or refuses `SubjectKeyDestructionRefused`, and `KeyDestroyer` binds it
   to the `key_vault` port's `destroy`. The ask is handed the subject's held state, so it takes no
   argument.
3. **System-only commands record the answer.** `MarkShredded` moves `shredding` to `shredded` and
   emits `SubjectKeyShredded`, the event it always emitted, now only after the vault answered.
   `FailShred` moves `shredding` to `shred_failed`, a failure state, and keeps the reason. Both
   are role "System", so no caller can reach `shredded` by saying so.
4. **A failed shred is retryable.** `Shred` is allowed from `shred_failed`, so a privacy officer
   asks again once the vault is back, and the key stays live until it answers.
5. **`Ports::KeyVault.shred!` shrinks to a dispatch of `Shred`.** The order it enforced is the
   model's. It still declines a subject with no key, or one already `shredded` or `shredding`.
6. **A framework member may ship its wiring.** `Framework.load!` now also loads
   `<name>.ports.hecksagon` and `<name>.*.adapter` beside a member's bluebook, as `Chapters`
   does for the bluebooks it carries. Until now a framework member could declare no port.

## Alternatives considered

- **Leave the order in `shred!`.** It is what shipped. Rejected: it is the rule outside the model.
- **A `given` on `Shred` that checks the vault.** The expression language cannot call a port, and
  ADR 0081's port-answered facts (`needs`) are not built.
- **Restrict `Shred` to "System" and let a Ruby helper check the officer's role.** It moves the
  authorization decision into Ruby, the wrong way.
- **Move Privacy into `Chapters` so it can ship a port.** It would cost Privacy its framework
  standing and the capability lookups that find it by declaration.

## Consequences

- **The contract verb changes meaning.** `shred` in `provides "subject_keys"` now names a request.
  A caller that destroys the key itself and then dispatches `shred` would destroy twice, which the
  vault reports as false and the record as shredded. In this repository only
  `Ports::KeyVault.shred!` dispatched it; callers in other repositories were not searched.
- **Existing rows stay valid.** `active` and `shredded` still exist and mean what they did. The
  shape ledger does not cover framework members, so no translation edge was written, and a deployed
  store holding `SubjectKey` rows was not checked.
- **Nothing here compiles it for Rust.** No bluebook in this repository attaches Privacy, so the
  generated host does not carry it. A consumer that attaches Privacy and builds for Rust would get
  the ask through the generator, which was not exercised here, and would need an adapter that
  answers the `Keys` port; the in-process vault is Ruby. `spec/corpus/privacy.json` replays
  unchanged under Ruby.
- **The in-process vault is not durable** (its own comment says so). The ask changes nothing about
  that; a KMS adapter is the real answer to destruction surviving a restart.
- **`Issue` is not asked.** A subject's `key_reference` is still given to `Issue` as a string, not
  taken from a vault answer. Asking the vault to issue the key the same way is a later step.
