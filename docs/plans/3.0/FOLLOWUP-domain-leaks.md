# Follow-up: implementation leaking into the Hecks bluebooks (post-3.0)

Source: a grep scan of the three Hecks bluebooks plus knowledge of the runtime changes. The counts are
real but the scan is not a full audit of every adapter. Not on the 3.0 critical path: 3.0 ships the
bins-as-adapters build first, and these items change the language, so they are best done as 3.x work
(before 3.0 only where an item is already a breaking change, such as `answered_by`).

## Leaks into the domain

1. **Port names inside policies (largest).** 83 policy triggers name a port operation directly, such
   as `ModelCheckRun::DomainRuntime::Check`, and 28 queries carry `answered_by`. Asks are declared in
   the hecksagon, but the bluebook still spells the port to reach them.
   Fix: a policy says "ask for the check"; the hecksagon maps that to a port. Related to the
   `answered_by` removal already decided for 3.0.
2. **The run protocol is modelled as domain.** 17 aggregates start in a `requested` lifecycle and 49
   companion commands (accept, settle, abandon and similar) only record process outcomes. 15 `Report`
   value objects plus `Output` and `refusal` attributes hold raw subprocess text (171 attribute lines
   named run, refusal, report or output). An SME would not say "settle a style run".
3. **Operating handles as identity.** `RunKey` (11 uses) and `OperationKey` are caller-named handles;
   a domain expert would identify a check by which domain and when. Auto-minted keys hide this but do
   not remove it.
4. **Files and OS concepts as domain types.** `DomainPath` (4), `PathList`, `ScriptPath`,
   `OutputPath`, `PayloadFile`, `Address`, `Checkout`. Some descriptions name technologies (cargo,
   sqlite, wasm, postgres, stdout).
5. **Ruby-host concerns.** `namespace "Hecks::Domain"` is a Ruby module path in the language; `*Run`
   record names bend around module collisions; regex patterns avoid `\d` for engine portability.

## Leaks the other way, into wiring

- The `--wait` failure-state list (flagged, faulted, halted and so on) sits in `hecks.world`, but which
  states mean failure is domain knowledge and belongs on the lifecycle.
- The runtime special-cases the Hecks chapter's constants, and the launcher special-cases string
  answers.

## Clean

No environment variables, `bin/` paths or hostnames appear in the bluebooks.

## Suggested order

1. Item 1 (policies ask, hecksagon maps), which changes the language.
2. Item 2 and the failure-state move onto lifecycles, which also change the language.
3. Items 3 to 5, and the wiring-side leaks.

Each needs an ADR-level decision before code; verify the counts with a real audit first.
