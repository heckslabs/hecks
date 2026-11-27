# Migrating from Hecks 7.x to 8.0

**Status: release candidate for 8.0.0** (checked against `main` on 2026-11-27). It is final once
8.0.0 is tagged.

This is the one page to follow when you take 8.0.0. It lists every break in the order a project
meets them. Each item gives the old spelling, the new one and how to find what needs changing.
The [CHANGELOG](../CHANGELOG.md) entry for 8.0.0 has the full wording, under **Breaking**. The
decisions behind it are [ADR 0180](decisions/0180-a-process-manager-has-one-name-in-the-language-and-the-runtime.md)
(saga names), [ADR 0182](decisions/0182-one-postgres-adapter-picks-its-layout-from-the-hecksagon.md)
(the Postgres layout and the outbox refusal), [ADR 0194](decisions/0194-interviews-are-the-beginning-of-work.md)
(interviews) and [ADR 0205](decisions/0205-the-pipeline-is-its-own-project-switchyard-on-a-pinned-hecks.md)
(shipments and the Delivery bluebook).

## Do these first

1. Pin `hecks` 8.0.0.
2. If a domain has policies or process managers and is bound to `Heki`, `D1` or `LocalStorage`, do
   section 1 before you deploy. Boot refuses it until you do.
3. Search your hecksagons, worlds, context maps, scripts, CI jobs, hooks, Makefiles and docs for the
   names in sections 2 to 9 and change them.
4. Regenerate any `ir.json` you keep (section 7).
5. Run `hecks-parse closed --check` over your declaration files and fix what section 10 lists.
6. Run `hecks ModelCheckRun.model_check! --wait` and your own specs.

## 1. Reactions on an adapter with no outbox

A domain with a `process_manager`, or with events that a policy in any loaded bluebook hears, no
longer boots when it is bound to `Heki`, `D1` or `LocalStorage`. 7.x booted it with a warning. Boot
now raises `Hecks::Runtime::WiringError`:

```
<Domain> declares policies or process managers, but its persistence adapter (<Adapter>) has no
outbox, so a crash would lose its reactions …
```

Either bind an adapter with an outbox (`Postgres`, `PostgresEra`, `Sqlite` or `Memory`), or opt in to
inline reactions in the domain's hecksagon (a local overlay works too):

```ruby
inline_reactions true
```

Reactions then run inline with the boot warning, as they do in 7.x. `Lambda` is a remote runtime and
is not affected.

## 2. `Era` is `SchemaRevision`

The framework bluebook's `Era` aggregate is `SchemaRevision`. Its commands and queries keep their
verbs and arguments (`era.value=` stays `era.value=`), and only the prefix changes. Help prints the
Pascal form; the snake form also resolves.

| 7.x | 8.0 |
|---|---|
| `hecks era.hold_first!` | `hecks SchemaRevision.hold_first!` |
| `hecks era.rename_domain!` | `hecks SchemaRevision.rename_domain!` |
| `hecks era.merge_tail!` | `hecks SchemaRevision.merge_tail!` |
| `hecks era.reattest!` | `hecks SchemaRevision.reattest!` |
| `hecks era.backfill_projections!` | `hecks SchemaRevision.backfill_projections!` |
| `hecks era.compact!`, `era.compact_heki!` | `hecks SchemaRevision.compact!`, `.compact_heki!` |
| `hecks era.write_translation!` | `hecks SchemaRevision.write_translation!` |
| `hecks era.reconcile!` | `hecks SchemaRevision.reconcile!` |
| `hecks era.mint_held!` | `hecks SchemaRevision.mint_held!` |
| `hecks era.scaffold_translation`, `era.audit_translation`, `era.compose_translation` | `hecks SchemaRevision.scaffold_translation`, `.audit_translation`, `.compose_translation` |
| `hecks era.reconcile_plan`, `era.mint_plan` | `hecks SchemaRevision.reconcile_plan`, `.mint_plan` |
| `hecks era.attestation`, `era.compaction` | `hecks SchemaRevision.attestation`, `.compaction` |
| `hecks era.boot_status`, `era.boot_resolution`, `era.sqlite_status` | `hecks SchemaRevision.boot_status`, `.boot_resolution`, `.sqlite_status` |
| `hecks era.event_trace`, `era.projection_audit` | `hecks SchemaRevision.event_trace`, `.projection_audit` |

There is no old-name window: `era.*` is refused as an unknown command, and so is `revision.*`
(`Revision` is the Delivery aggregate behind `Revision.make!`, a different thing).

- **Events:** `EraRequested`, `EraPermitted`, `EraSettled`, `EraAbandoned`, `EraExamined`,
  `EraChanged` and `EraRefused` are `SchemaRevisionRequested`, `SchemaRevisionPermitted` and so on.
  Anything that listens for them by name must change.
- **World setting:** `minting commands: ["Era.MintHeld"]` is `["SchemaRevision.MintHeld"]`.
- **New:** `SchemaRevision.compact_events!` drops a Sqlite event log's events past a window of days,
  and `SchemaRevision.release_mint!`.
- **Find them:** `grep -rnE '\b[Ee]ra\.[a-z_]+' . | grep -v 'era\.value'` finds the command lines
  without the arguments, which do not change. Search for `Era[A-Z][a-z]+` event names and
  `"Era.MintHeld"` too.

## 3. Era helper constants in Ruby

These constants are renamed in the same namespaces, with no alias:

| 7.x | 8.0 |
|---|---|
| `Hecks::Era` | `Hecks::SchemaRevision` |
| `Fuzzing::EraBoundary` | `Fuzzing::RevisionBoundary` |
| `Runtime::EraCheck`, `EraGuard`, `EraStatus`, `EraTamper` | `Runtime::RevisionCheck`, `RevisionGuard`, `RevisionStatus`, `RevisionTamper` |
| `PostgresEra::Lineage::EraIntegrity`, `EraStore` | `PostgresEra::Lineage::RevisionIntegrity`, `RevisionStore` |
| `PostgresEra::LineageManager::EraResolution`, `EraResolver`, `HeldEra` | `PostgresEra::LineageManager::RevisionResolution`, `RevisionResolver`, `HeldRevision` |
| `Tools::EraProjectionBackfill`, `EraReattest`, `ExpectedEra` | `Tools::RevisionProjectionBackfill`, `RevisionReattest`, `ExpectedRevision` |
| `Adapters::QaEraMint` | `Adapters::QaRevisionMint` |

These keep their names: `Hecks::Adapters::PostgresEra` (and its `postgres_era` adapter key, see
"Not in 8.0"), `Ports::Persistence::Plugins::Era`, `Tools::CheckEra`, `Host.check_era!` and
`Maintenance.mint_era!`. File names are unchanged (`era_check.rb`, `postgres_era/…`), and so are
the stored names: the `hecks_eras` and `hecks_era_texts` tables and the `hecks_current_era`
row-level-security policy. `expected-era` and the hosting setting `expected_eras` are unchanged.
No data migration is needed.

## 4. Context map spellings

In a `.contextmap`:

- `as: :anticorruption_layer` → `as: :anti_corruption_layer`
- `relate "A" => "B", acknowledges: { … }` → `relate "A" => "B", accepted_findings: { … }`

Both old spellings raise `ArgumentError` when the map loads. The old keyword's message reads
`relate takes one "Upstream" => "Downstream" pair`, which does not name it, so look for
`acknowledges:` on a `relate` line when you see that. An aggregate's `acknowledges :finding, "reason"`
in a bluebook is unchanged.

## 5. Composer timeline key

`POST /composer/timeline` answers `{ "saves": [{name, at, text}, …] }`, where 7.x answered
`{ "revisions": … }`. Anything that reads the Composer's timeline JSON must read `saves`.

## 6. The world verb `event_log`

The world verb `event_log` is `event_tap`. A world that still says `event_log` is refused at boot
with a message naming `event_tap`. Rename it in every `.world` file.

## 7. Saga names in the IR and in Ruby

The IR's top-level `process_managers` key is `sagas`. `ir_version` stays 1, so an `ir.json` written by
7.x is not refused: its sagas are dropped without an error. Regenerate every `ir.json` you keep, and
change any tool that reads the IR to read `sagas`.

In Ruby, with no aliases:

- `Bluebook::ProcessManager` → `Bluebook::Saga`, and `ProcessManagerHandler` → `SagaHandler`
- the old compensation Struct `Bluebook::Saga` → `Bluebook::Compensation`, so code that still calls
  `Bluebook::Saga.new(trigger: …)` fails with an error rather than doing the wrong thing
- `Behaviour::ProcessManager` → `Behaviour::Saga`
- `Declaration#process_managers` → `#sagas`
- `DSL::ProcessManagerBuilder::InvalidProcessManager` → `InvalidSaga`

The bluebook keyword is still `process_manager`, and the saga stores' `process_manager` column keeps
its name.

## 8. Storehouse, persistence adapters and the event pump

- `Storehouse::Audit` → `Storehouse::Trace`: `#audited` → `#traced`, `#audit_fields` →
  `#trace_fields`, and the audit line is `trace_line`. `Storehouse.log_root`, `log_path`,
  `log_lines` and the files on disk keep their names.
- A custom persistence adapter's `atomic_put` now receives `replace_when:` on every write. Add
  `replace_when: nil` to its signature; an adapter that does not take it raises.
- PostgresEra now refuses a boot when an aggregate would be stored under a name with no journal rows
  while an earlier name holds some. 7.x booted it over an empty store. Add the `stored_as` line the
  refusal names.
- QualityControl attaches the `EventDelivery` framework member. `EventCursor`, `EventReaction`,
  `EventPump`, `EventPump.pump!` and the `qa_event_pump` row are gone; a run is `Pump.run!` on
  EventDelivery.

## 9. CLI commands that are gone or changed

- **`hecks interview` and `Launch.interview!` are removed**, with their `expert` and `no_ai`
  arguments, the `interview_*` tools and the SME bluebook. Record an interview with the Interviews
  bluebook instead:

  ```
  hecks interviews Interview.record! reference.value=<ref> subject.value=<subject> keeping.value=local speaker.value=<who> answer.value=<text>
  hecks interviews Interview.record! reference.value=<ref> speaker.value=<who> answer.value=<text>
  hecks interviews Interview.conclude! to=<ref>
  ```

  The first turn carries `subject` and `keeping` (`committed` or `local`); later turns leave them
  out. `Interview.conclude!` is refused while a Point is still open.
- **`Shipment.ship!` takes no `paths`** and no longer fixes comment style. Call
  `hecks Shipment.ship! branch.value=<b> checkout.value=<dir> --confirm`, and run the comment fix
  yourself first if you relied on it. The stages `fixing`, `checking` and `gated` are gone; the saga
  runs `judging`, `landing` and `boarding`, and `hecks Shipment.rejudge!` (or `hecks resume <run>`)
  retries a refused gate. Finish or abandon a shipment parked at an old stage before you upgrade,
  since it has no resume command any more.
- **`hecks checkout.log` is gone.** Use `hecks workspace.history`.
- **Landing, LinkedTree, Revision and Workspace's status, changes and history now come from the
  vendored Delivery bluebook.** On the command line nothing changes: `hecks Landing.finish!` and the
  others still resolve, and help prints them as `hecks delivery Landing.finish!`. Code that names
  them by qualified name or by domain must use `Delivery::Landing` and the others (was
  `Hecks::Landing`).

## 10. Declaration files are parsed, not run

The gem no longer runs a `.bluebook`, `.hecksagon`, `.world` or `.contextmap` file as Ruby.
The Rust parser (`hecks-parse`, in `rust/parser`) checks each file against the closed
vocabulary: declaration words with literal arguments, rule expressions in `given`,
`invariant`, `ensures` and `where`, operand arithmetic in `sets`, and the bind and setting verbs
of a hecksagon and a world. The gem builds only from the text the parser admits. A file that
holds anything else is refused before any of it runs, with the file, the line and the reason.

These are refused:

- `require`, `load`, `eval`, `send`, `system`, backticks and any other Ruby method.
- `ENV`, `File`, `Dir` and any other constant at the start of a line or in an argument.
- String interpolation, lambdas, blocks on arguments and `.each` or `.times` loops.
- Method calls inside a rule body, other than the rule words themselves.

What to change:

- **Loops:** write each declaration out. `%w[A B].each { |n| separate_ways n, "C" }` becomes
  one `separate_ways` line per name.
- **Settings read from the environment or a file:** move them behind an adapter, and have the
  world name the adapter.
- **A hecksagon that loaded its own bluebook with `load` or `require`:** write
  `bluebook_from :gem` as the first line of its `Hecks.hecksagon` block.
- **A path built with `File.expand_path` or `__dir__`:** write the path as a literal. A world
  may write `~/` and the adapter expands it.

**The parser binary.** The gem runs `hecks-parse`. Set `HECKS_PARSE_BIN` to a built binary, or
have `cargo` (Rust 1.98.0) on the `PATH`, in which case the gem builds it once into its cache
directory for each version of the parser sources. With neither, loading a declaration file
raises `Hecks::ClosedForm::Parser::Missing`, which names both.

Run `hecks-parse closed --check <files>` to list every file of yours that the parser refuses.

## Not in 8.0

- **The `postgres_era` adapter key stays.** `PostgresEra` boots as it does in 7.x, and nothing
  refuses or deprecates it. The hecksagon word `revisions true` is new and is accepted on `Postgres`
  and `PostgresEra`, but keep binding `PostgresEra` for now: the move to `Postgres` with
  `revisions true` (ADR 0182) is not finished, and the layout record that would refuse a later
  mismatch is not built.
- **The `saga` bluebook keyword.** ADR 0180 plans it; `process_manager` is still the only word.
- **Refusing a caller with no stated role (ADR 0216).** Role-gated commands with no caller are
  counted in shadow and refuse nothing yet.
- **Renaming the stored `hecks_*era*` names.**
