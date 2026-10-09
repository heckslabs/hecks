# Follow-up: implementation leaking into the Hecks bluebooks (post-3.0)

Source: a grep scan of the three Hecks bluebooks plus knowledge of the runtime changes. The counts are
real but the scan is not a full audit of every adapter. Not on the 3.0 critical path: 3.0 ships the
bins-as-adapters build first, and these items change the language, so they are best done as 3.x work
(before 3.0 only where an item is already a breaking change, such as the `answered_by` removal, which is done).

## Leaks into the domain

1. **Port names inside policies (largest).** 83 policy triggers name a port operation directly, such
   as `ModelCheckRun::DomainRuntime::Check`, and the outside-answered queries are now bound in the hecksagon (`answers_query`) rather than
   carrying `answered_by`. Asks are declared in the hecksagon, but the bluebook still spells the port
   to reach them.
   Fix: a policy says "ask for the check"; the hecksagon maps that to a port. The queries are the part already done for 3.0.
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

## Status, 2026-10-09

Done:

- The `--wait` failure-state list left the worlds. ADR 0097's lifecycle `mark` carries it: each lifecycle
  with failing states says `mark :failure, ...`, the launcher reads the mark, and `failure_states` is
  gone from `hecks.world`, `deploy.world` and `site.world`. A spec asserts any state named like a
  failure is marked.
- The runtime no longer recognises the Privacy chapter by name. `provides "privacy"` and
  `provides "subject_keys"` (added to `Bluebook::Capabilities`) name the verbs that boot, the masking of
  a read and the cryptoshred call.

Left as is, on purpose: the literal `"Hecks"` in `HecksagonBuilder`, its chapter scope and the
chapter-name validation. They guard the gem's own Ruby module `Hecks`, which the chapter's aggregates
would collide with; that is a fact about the Ruby host, not a domain fact, and no capability fits it.
Removing it means the chapter stops being named `Hecks` or the constants stop living in that module
(item 5).

Audit, re-counted on this date over every `.bluebook` under `lib/hecks`:

- Policy triggers that name a port operation (`Aggregate::Port::Operation`): 133, up from 83. By file:
  `codebase` 63, `deploy` 21, `tooling` 18, `custodian` 17, `tickets` 8, `site` 4, `quality_control` 2.
- Lifecycles that start in `requested`: 36, up from 17 (`deploy` 15, `codebase` 11, `tooling` 6,
  `custodian` 3, `site` 1).
- `Report` value objects: 34, up from 15. The numbers grew because new chapters follow the same
  run-protocol shape; nothing has reduced it.
- Not re-counted: the companion commands and the attribute lines named run, refusal, report or output.

The leak is growing with each chapter, so the order below holds and item 1 is now the cost-reducing step.

Recommended next step: write the ADR for item 1 before any code. The decision it must make is the
hecksagon vocabulary that maps a policy's ask to a port operation (for example a policy says
`ask :check`, and the hecksagon binds `check` to `ModelCheckRun::DomainRuntime::Check`), with the
Ruby and Rust parsers and the conformance corpus moving together. Start with the 18 triggers in
`tooling.bluebook`, one chapter, to prove the shape before the rest follow.

## Suggested order

1. Item 1 (policies ask, hecksagon maps), which changes the language.
2. Item 2 and the failure-state move onto lifecycles, which also change the language.
3. Items 3 to 5, and the wiring-side leaks.

Each needs an ADR-level decision before code; verify the counts with a real audit first.
