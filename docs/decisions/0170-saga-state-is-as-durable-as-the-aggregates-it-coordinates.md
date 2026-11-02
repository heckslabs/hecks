# Saga state is as durable as the aggregates it coordinates

**Status:** Proposed. Date: 2026-11-02.

## Context

A process manager's state (which leg it is on, what it remembers, which compensations ran) is kept by
the saga store that `Registry#saga_persistence` resolves (`lib/hecks/runtime/registry/saga_persistence.rb`).
`resolve_saga_persistence` takes the domain's first aggregate as its anchor and uses that aggregate's
adapter when the adapter answers `save_saga`; otherwise it answers `NULL_SAGA_STORE`, which keeps
nothing. Heki, Sqlite, Postgres and PostgresEra answer `save_saga`; Memory does not.

When everything is in Memory this is consistent: a restart forgets the aggregates and the sagas
together. The hazard is the mixed case, where the aggregates survive a restart and the saga does not.
A transfer has debited one account, the process restarts, the saga that was waiting to credit the other
account (or to reverse the debit) is gone, and nothing reports it. There are four ways to reach it today:

1. **A domain with no hecksagon but a durable world.** `saga_domains` includes a bluebook that has only a
   world `default_adapter`, but `resolve_saga_persistence` returns the null store whenever the domain has
   no hecksagon (`saga_persistence.rb`, the `return … unless anchor` line). The aggregates are durable
   through ADR 0136's resolution order; the saga store is not.
2. **A custom adapter without `save_saga`.**
3. **Mixed binds whose anchor aggregate is in Memory** while others are durable.
4. **`RemoteRuntime`**, which always resolves to the null store.

The only signal is `warn_undurable_sagas!` (`registry/durability_warnings.rb`), a warning printed at boot
for any domain with process managers and a null saga store. It runs inside `verify_hecksagon!`, so case 1,
which has no hecksagon, never sees it.

## Decision

1. **Resolve the saga store the same way with or without a hecksagon.** A domain with no hecksagon
   resolves its anchor through `Ports::Persistence::BindingPolicy.resolve`, as a domain with one does.
   This closes case 1 without any new rule.
2. **Refuse the mixed case at boot.** A registry-level check iterates every bluebook that declares a
   process manager (not `saga_domains`, which omits an attached bluebook whose durable default is
   inherited through `BindingPolicy`, and not each hecksagon). It refuses a domain when any aggregate its
   managers dispatch to resolves to an adapter other than Memory while the saga store resolves to
   `NULL_SAGA_STORE`. The check resolves each aggregate through `BindingPolicy.resolve` itself, so an
   unbound aggregate raises its own wiring error; it does not read "null store" from `saga_persistence`,
   which answers the null store for a swallowed `WiringError`. The refusal is a `WiringError` in ADR
   0136's wording for a forgotten decision: it names the domain, the durable aggregate and the adapter,
   and says how to fix it (bind the anchor to a store that keeps sagas, or keep the whole domain in
   Memory on purpose).
3. **`RemoteRuntime` is exempt.** The remote side holds the saga; this runtime only forwards.
4. **All-Memory is unchanged.** It is not refused, and the existing warning stays for it, as
   `spec/runtime/registry/undurable_saga_warning_spec.rb` and `spec/quality_control_spec.rb` assert.
5. **The warning is dropped only where the refusal takes over.** A case the refusal covers no longer also
   warns; every other case keeps the warning it has today.

## Consequences

- A domain that boots today with durable aggregates and forgetful sagas stops booting, with a message
  that names the fix, where today it boots and can lose a compensation on its first restart.
- `spec/runtime/registry/saga_persistence_spec.rb`'s bare-domain example keeps passing: a bluebook with
  no world resolves to Memory, and Memory answers the null store. A new example covers a domain with no
  hecksagon and a world `default_adapter` that answers `save_saga`. The warning specs above keep
  passing for all-Memory domains.
- The check sits beside the other boot refusals (`registry/hecksagon_rules.rb`, the boot gates of
  ADR 0031) and reads binds only through `BindingPolicy`, so attached domains resolve through their
  chapter root as ADR 0136 says.
- The outbox already holds the same line for events owed to a saga (ADR 0053): an outbox row commits in
  the same transaction as the aggregate. This ADR holds the saga's own state to it.

## Alternatives considered

- **Keep only the warning.** Rejected: a boot warning is read once and then scrolled past, and case 1
  never prints it.
- **Give Memory a `save_saga`.** Worth doing for parity between tests and production, and independent of
  this decision: it changes nothing about the mixed case, where the anchor is durable or absent.
- **Refuse any domain with process managers and a null store.** Rejected: it would refuse every
  all-Memory test and development boot, where losing everything together is correct.

## Open question

- How an attached bluebook's sagas are run and checkpointed was not traced for this ADR; the check in
  item 2 assumes they resolve through the attaching chapter's root, and the implementation confirms it.
