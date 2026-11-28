# Migrating from Hecks 7.x to 8.0

**Status: release candidate for 8.0.0** (checked against `main` on 2026-11-28). It is final once
8.0.0 is tagged.

This is the one page to follow when you take 8.0.0. It lists every break in the order a project
meets them. Each item gives the old spelling, the new one and how to find what needs changing.
The [CHANGELOG](../CHANGELOG.md) entry for 8.0.0 has the full wording, under **Breaking**. The
decisions behind it are [ADR 0180](decisions/0180-a-process-manager-has-one-name-in-the-language-and-the-runtime.md)
(saga names), [ADR 0182](decisions/0182-one-postgres-adapter-picks-its-layout-from-the-hecksagon.md)
(the Postgres layout and the outbox refusal), [ADR 0194](decisions/0194-interviews-are-the-beginning-of-work.md)
(interviews), [ADR 0205](decisions/0205-the-pipeline-is-its-own-project-switchyard-on-a-pinned-hecks.md)
(the pipeline's move to Switchyard), [ADR 0207](decisions/0207-no-two-contexts-depend-on-each-other-and-a-standing-cycle-is-deprecated.md)
(context cycles) and [ADR 0216](decisions/0216-a-role-gated-command-refuses-a-caller-who-states-no-role.md)
(the caller's role).

## Do these first

1. Pin `hecks` 8.0.0.
2. If a domain has policies or sagas and is bound to `Heki`, `D1` or `LocalStorage`, do section 1
   before you deploy. Boot refuses it until you do.
3. If a hecksagon or world names `PostgresEra` or `postgres_era`, do section 2 before you deploy.
   Boot refuses it until you do.
4. Run `hecks ConformanceRun.report_role_shadow! domain.value=<dir> --wait` and clear what it lists
   (section 3). Set `HECKS_ROLE_ENFORCEMENT=shadow` while you do, if you must deploy first.
5. If a hecksagon attaches a bluebook that section 15 lists, or a script runs the pipeline's
   commands, do section 15. Boot refuses the attach until you do.
6. Search your hecksagons, worlds, context maps, scripts, CI jobs, hooks, Makefiles and docs for the
   names in sections 4 to 12 and change them, including any `query` or `ask` before a query.
7. Regenerate any `ir.json` you keep (section 9).
8. Run `hecks-parse closed --check` over your declaration files and fix what sections 9 and 13 list.
9. Run `hecks ModelCheckRun.model_check! --wait`, fix any `context_cycle` error (section 14), and run
   your own specs.

## 1. Reactions on an adapter with no outbox

A domain with a `saga`, or with events that a policy in any loaded bluebook hears, no longer boots
when it is bound to `Heki`, `D1` or `LocalStorage`. 7.x booted it with a warning. Boot now raises
`Hecks::Runtime::WiringError`:

```
<Domain> declares policies or sagas, but its persistence adapter (<Adapter>) has no outbox, so a
crash would lose its reactions …
```

Either bind an adapter with an outbox (`Postgres`, in either layout, `Sqlite` or `Memory`), or opt
in to inline reactions in the domain's hecksagon (a local overlay works too):

```ruby
inline_reactions true
```

Reactions then run inline with the boot warning, as they do in 7.x. `Lambda` is a remote runtime and
is not affected.

## 2. `PostgresEra` is `Postgres` with `revisions true`

8.0 has one Postgres adapter. The domain's hecksagon picks the layout: `persisted_by "Postgres"`
alone keeps one table per aggregate, and `revisions true` beside it keeps the revision layout, the
held eras, translations and write fence that 7.x called `PostgresEra`.

Before (7.x):

```ruby
# directory.hecksagon
Hecks.hecksagon "Directory" do
  Directory::Member.persisted_by("PostgresEra")
end

# directory.world
Hecks.world "Directory" do
  persisted_by("PostgresEra") do
    database "postgres://localhost/hecks_directory"
  end
end
```

After (8.0):

```ruby
# directory.hecksagon
Hecks.hecksagon "Directory" do
  Directory::Member.persisted_by("Postgres")
  revisions true
end

# directory.world
Hecks.world "Directory" do
  persisted_by("Postgres") do
    database "postgres://localhost/hecks_directory"
  end
end
```

A domain whose world binds every aggregate with `default_adapter "PostgresEra"` writes
`default_adapter "Postgres"` there and `revisions true` in its own hecksagon.

A hecksagon or world that still names `PostgresEra` or `postgres_era` (any case) is refused at boot,
before any adapter loads, with `Hecks::Runtime::WiringError`:

```
Lending: its hecksagon binds PostgresEra, which Hecks 8.0 removed. Write persisted_by "Postgres" plus `revisions true` in the hecksagon (ADR 0182) instead: PostgresEra is now Postgres's revision layout, chosen in the hecksagon.
```

A world reads `its world names PostgresEra` in the same place, and a lookup of the class by name
(`AdapterNamespace.resolve`) reads `Hecks: an adapter lookup names postgres_era`. The Rust host
refuses an IR that binds it with the same sentence, naming the aggregate
(`Shop: Order binds PostgresEra, which Hecks 8.0 removed. …`), and serves only `Postgres` and
`Memory`.

**The layout is recorded.** Each database keeps a `hecks_layouts` row per domain (`table` or
`revisions`). Once a domain has data, a boot that would change its layout is refused. If you change
`PostgresEra` to `Postgres` and forget `revisions true`, boot says:

```
cannot boot Directory in Postgres's table layout: its database holds Directory in the revisions layout, and a layout cannot change once data exists. To keep the data, keep `revisions true` in its hecksagon; to start over, point the world at a database that holds no Directory.
```

**Settings only the revision layout reads.** `formerly`, `allow_superuser`, `mint_eras`,
`disposable_ledger` and `mints_era` in a world's `persisted_by("Postgres")` block need
`revisions true` in the domain's hecksagon. Without it:

```
Directory binds Postgres without revisions, but its world sets :allow_superuser, which only the revision layout reads. Add `revisions true` to Directory's hecksagon, or remove the setting from the world.
```

`revisions true` needs at least one of the domain's aggregates bound to `Postgres`; the others may
stay in Memory. With none, boot says
`Directory sets revisions, but its persistence adapter is Memory — revisions need one of Postgres`.

- **No data migration.** The stored names (`hecks_eras`, `hecks_era_texts`, the
  `hecks_current_era` row-level-security policy) are unchanged, and a database written before
  `hecks_layouts` existed is read by its own evidence: held eras mean the revision layout.
- **Ruby names that stay:** `Hecks::Adapters::PostgresEra`, its `postgres_era/` files and the
  `PostgresEra::…` constants in section 5 are the revision layout's implementation. Code may still
  name them; a binding or a lookup by adapter name may not.
- **Find them:** `grep -rniE 'postgres_?era' --include='*.hecksagon' --include='*.world' .`, plus any
  Ruby that resolves an adapter by the name `"PostgresEra"`.

## 3. A role-gated command needs a stated role

A command that declares `role` now refuses a caller who states none. 7.x ran it and counted the
would-refuse; 8.0 refuses by default in the Ruby runtime and the Rust host
(`HECKS_ROLE_ENFORCEMENT` unset, or any word but `shadow` and `off`, is `enforce`).

Before (7.x), with `order.create_pizza!` declaring `role "Chef"`, this ran:

```
hecks order.create_pizza! name=Margherita pizza.price_cents.cents=1200 pizza.size.value=large
```

In 8.0 it exits 1 with:

```
[unauthorized] CreatePizza refused — role: Chef, and the caller stated no role
```

After:

```
hecks order.create_pizza! name=Margherita pizza.price_cents.cents=1200 pizza.size.value=large --as Chef
```

What counts as stating a role:

- **A launcher line** states it with `--as <Role>` or `--as=<Role>`. A bare `--as` is refused
  (`hecks: --as needs a role, as in --as Maintainer`, exit status 2). Or list the roles whoever runs
  the launcher holds in the world's `launcher` setting, and a line with no `--as` runs as the first
  of them its command declares:

  ```ruby
  launcher "Launcher", caller_roles: ["Operator", "System"]
  ```

  Leave an owner's role out of the list, so a line has to state it.
- **An MCP call** passes `role:` (and `actor_id:` where it has one), as before.
- **A Rust host request** on the internal protocol carries a role or an `actor_id`. A caller built
  as `dispatch::Caller::default()` (no role, no actor) is dispatched as `Anonymous` and refused.
- **A direct Ruby call** with no caller bound is the process acting for itself and still runs; it
  is counted in `unstated_caller_log` as `internal`.

**Policies.** A reaction runs as its policy's `acts_as`. A policy that declares none is the caller
who stated no role in a cascade an outside caller began, so a role-gated trigger refuses it: the
command that caused it commits, and the reaction is recorded as refused with
`Review refused — role: Reviewer, and the caller stated no role`. Give the policy the role:

```ruby
policy "RetryOnPaymentFailure" do
  on      ScheduledPayment::ScheduledPaymentFailed
  acts_as "System"
  trigger ScheduledPayment::Retry
end
```

For a bluebook whose files you do not edit, such as a vendored package, give every policy that
declares no `acts_as` one role where you attach it:

```ruby
attaches "payments", from: :vendor, acts_as: "System"
```

A saga leg runs unchecked.

**`policy_only`.** A command that says `policy_only` refuses every caller that is not a reaction,
whatever role it states:

```
Water refused — only a policy reaction may dispatch it, and a caller did
```

- **Find them:** `hecks ConformanceRun.report_role_shadow! domain.value=<dir> --wait` reads a
  directory's declarations and lists each role-gated command a caller may dispatch, each policy whose
  target is one and that declares no `acts_as`, each policy whose `acts_as` its target does not
  declare, and each saga leg, with what clears each kind of row.
- **While you migrate:** `HECKS_ROLE_ENFORCEMENT=shadow` lets the unstated caller through and writes
  one `would_refuse_role` line to stderr for the first count of each domain, command and origin.
  `off` checks nothing for a caller who states no role. A caller who states the wrong role is refused
  in every mode.

## 4. `Era` is `SchemaRevision`

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

## 5. Era helper constants in Ruby

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

These keep their names: `Hecks::Adapters::PostgresEra`, now the class behind Postgres's revision
layout and no longer an adapter a hecksagon or world may name (section 2),
`Ports::Persistence::Plugins::Era`, `Tools::CheckEra`, `Host.check_era!` and
`Maintenance.mint_era!`. File names are unchanged (`era_check.rb`, `postgres_era/…`), and so are
the stored names: the `hecks_eras` and `hecks_era_texts` tables and the `hecks_current_era`
row-level-security policy. `expected-era` and the hosting setting `expected_eras` are unchanged.
No data migration is needed.

## 6. Context map spellings

In a `.contextmap`:

- `as: :anticorruption_layer` → `as: :anti_corruption_layer`
- `relate "A" => "B", acknowledges: { … }` → `relate "A" => "B", accepted_findings: { … }`

Both old spellings raise `ArgumentError` when the map loads. The old keyword's message reads
`relate takes one "Upstream" => "Downstream" pair`, which does not name it, so look for
`acknowledges:` on a `relate` line when you see that. An aggregate's `acknowledges :finding, "reason"`
in a bluebook is unchanged.

## 7. Composer timeline key

`POST /composer/timeline` answers `{ "saves": [{name, at, text}, …] }`, where 7.x answered
`{ "revisions": … }`. Anything that reads the Composer's timeline JSON must read `saves`. The
Composer itself moves to Switchyard with the pipeline (section 15).

## 8. The world verb `event_log`

The world verb `event_log` is `event_tap`. A world that still says `event_log` is refused at boot
with a message naming `event_tap`. Rename it in every `.world` file.

## 9. Sagas: the keyword, the IR and Ruby

**The keyword.** A saga is declared with `saga`. The words inside it do not change.

Before (7.x):

```ruby
process_manager "Onboarding" do
  correlates_by :"reference.value"
  starts_on "OnboardingOpened"
  ends_on   "AccountOpened"
  transition "OnboardingDeclined" => "declined", from: "screening"
end
```

After (8.0):

```ruby
saga "Onboarding" do
  correlates_by :"reference.value"
  starts_on "OnboardingOpened"
  ends_on   "AccountOpened"
  transition "OnboardingDeclined" => "declined", from: "screening"
end
```

A bluebook that still says `process_manager` is refused when it loads, with
`Hecks::ClosedForm::Refused`:

```
lib/shop/shop.bluebook:12: process_manager is gone — saga is the word now
```

`hecks-parse closed --check` prints the same line for each file, and the Ruby DSL raises
`Hecks::Bluebook::DSL::Malformed` with the same words after the colon. Era text the revision layout
already holds is not affected: the gem reads it with `hecks-parse closed --frozen`, which keeps the
old spelling, so no data migration is needed.

**The IR.** The top-level `process_managers` key is `sagas`. `ir_version` stays 1, so an `ir.json`
written by 7.x is not refused: its sagas are dropped without an error. Regenerate every `ir.json`
you keep, and change any tool that reads the IR to read `sagas`.

**Ruby**, with no aliases:

- `Bluebook::ProcessManager` → `Bluebook::Saga`, and `ProcessManagerHandler` → `SagaHandler`
- the old compensation Struct `Bluebook::Saga` → `Bluebook::Compensation`, so code that still calls
  `Bluebook::Saga.new(trigger: …)` fails with an error rather than doing the wrong thing
- `Behaviour::ProcessManager` → `Behaviour::Saga`
- `Declaration#process_managers` → `#sagas`
- `DSL::ProcessManagerBuilder` → `DSL::SagaBuilder`, and `InvalidProcessManager` →
  `SagaBuilder::InvalidSaga`
- the query-IR construct kind `ProcessManager` → `Saga`

**Messages.** The no-outbox refusal now says `declares policies or sagas`, and the warning for a
missing `save_saga` says `declares saga(s)`. Anything that matches on the old words must change.

The saga stores' `process_manager` column keeps its name.

- **Find them:** `grep -rn 'process_manager ' --include='*.bluebook' .`, or run
  `hecks-parse closed --check` over your declaration files; search Ruby for `ProcessManager`.

## 10. Storehouse, persistence adapters and the event pump

- `Storehouse::Audit` → `Storehouse::Trace`: `#audited` → `#traced`, `#audit_fields` →
  `#trace_fields`, and the audit line is `trace_line`. `Storehouse.log_root`, `log_path`,
  `log_lines` and the files on disk keep their names.
- A custom persistence adapter's `atomic_put` now receives `replace_when:` on every write. Add
  `replace_when: nil` to its signature; an adapter that does not take it raises.
- Postgres's revision layout (7.x's `PostgresEra`) now refuses a boot when an aggregate would be
  stored under a name with no journal rows while an earlier name holds some. 7.x booted it over an
  empty store. Add the `stored_as` line the refusal names.
- QualityControl, which moves to Switchyard (section 15), attaches the `EventDelivery` framework
  member. `EventCursor`, `EventReaction`, `EventPump`, `EventPump.pump!` and the `qa_event_pump`
  row are gone; a run is `Pump.run!` on EventDelivery.

## 11. CLI commands that are gone or changed

Each replacement this section names belongs to the pipeline, which runs from Switchyard from 8.0
(section 15), so run it from a Switchyard checkout.

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

## 12. Old command names and the query word

8.0 keeps no old command names. 7.x answered an old spelling through the launcher's `renamed` table
and through an aggregate's `formerly_known_as`, and printed the new spelling once. Both are gone.

| 7.x | 8.0 |
|---|---|
| `hecks push_train.push!` | `hecks SendTrain.send!` |
| `hecks pull_request.merge!` | `hecks ReviewRequest.take!` |
| `hecks <former>.<verb>!`, for an aggregate with `formerly_known_as "<Former>"` | `hecks <Aggregate>.<verb>!` |
| `hecks query SchemaRevision.boot_status`, `hecks ask SchemaRevision.boot_status` | `hecks SchemaRevision.boot_status` |

An old spelling is refused like any name the bluebook does not declare, with exit status 2:

```
[unknown_command] no such command: Entry.post
```

The refusal lists current names that share a prefix with what you typed, under `did you mean:`.
`SendTrain` and `ReviewRequest` move to Switchyard with the pipeline (section 15), so their new
names run from Switchyard's launcher.

`query` before a query is refused, with exit status 2, unless a command of the same bluebook has the
same name:

```
hecks: query is needed only where a command shares the name; write Loan.everything bare
```

Where a command and a query do share a name, `query` still reaches the query, since the bare name
reaches the command.

`ask` is not a query word any more: `hecks ask order.available` is refused as
`[unknown_command] no such command: ask`.

- **What to change:** every script, CI job, hook, Makefile and generator that types an old name,
  `query <name>` or `ask <name>`. The MCP door resolves names as the launcher does, so an MCP
  client that sends an old name gets nothing back for it.
- **Unchanged:** a short name, the snake-case form of a current name
  (`schema_revision.hold_first!`), and `formerly_known_as` as the name of the table an aggregate's
  rows were written under. A world whose `launcher` setting still lists `renamed:` has the key
  ignored; delete it.
- **Find them:** `grep -rnE '\b(push_train\.push|pull_request\.merge)\b|hecks (query|ask) ' .`, and
  search for the former name of each aggregate that says `formerly_known_as`.

## 13. Declaration files are parsed, not run

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

## 14. Context cycles are refused, accepted or not

`model_check` reads four kinds of edge between contexts: `attaches`, `subscribe`, an `across`
policy and a `translates`. Two contexts that reach each other through them are a cycle, and a cycle
is an error. 7.x let a `.contextmap` accept one on its relationship and reported it as deprecated:

```ruby
relate "Right" => "Left", as: :customer_supplier, accepted_findings: { context_cycle: "stood before" }
```

8.0 refuses it anyway. The map still loads, so the project boots, and `model_check` exits 1 with:

```
ERROR   context_cycle        Left <-> Right  —  these contexts depend on each other: Left, Right — a context is upstream of another or downstream of it, never both; move the reactions to one side's hecksagon, or make them one context; the context map accepts the cycle between Left and Right (accepted_findings: { context_cycle: ... }), which excuses no cycle from 8.0.0
```

A cycle with no acceptance gets the same line without the part after "make them one context".

What to change:

- **Make one context upstream.** Move the reactions the downstream context holds to the upstream
  context's events into the upstream context's hecksagon, as `translates … across` into the
  downstream context's command. An `attaches` now acknowledges an `across` to the same context, so
  a context may call the commands of a context it attaches from its own events.
- **Or make the two one context**, when neither can be read without the other.
- **Then remove the acceptance.** Once the wiring has no cycle, `model_check` reports the leftover
  line as a warning until you delete `context_cycle` from that relationship's `accepted_findings`:

  ```
  WARNING context_cycle_settled Left <-> Right  —  the context map accepts a cycle between Left and Right, and the wiring has none — remove `context_cycle` from the relationship's accepted_findings, which excuses nothing from 8.0.0
  ```

- **Find them:** `grep -rn 'context_cycle' --include='*.contextmap' .`, then run
  `hecks ModelCheckRun.model_check! --wait`.

## 15. The development pipeline leaves Hecks for Switchyard

The pipeline that lands work on `main`, and the tooling around it, is its own Hecks project from
8.0: Switchyard ([ADR 0205](decisions/0205-the-pipeline-is-its-own-project-switchyard-on-a-pinned-hecks.md)).
It stands on a pinned Hecks as a client project does. What leaves the gem:

- **The pipeline:** landings, the train, the red flag, dispatch, the stall watch and the pipeline's
  other modules of the Hecks domain under `lib/hecks/hecks/`, with their adapters and their lines in
  `hecks.world`, and the vendored Delivery bluebook (`Landing`, `LinkedTree`, `Revision`,
  `SendTrain`, `ReviewRequest`, `Shipment` and Workspace's git questions).
- **The bluebooks around it:** the board (`PipelineBoard`), the agents, the coder, the fixer,
  triage, Signalbox, Roundhouse, the CI pipeline (the bluebook that generated the workflows), the
  gate memo, CI speed, the catcher and the context budget.
- **The Composer, Interviews and the SME bluebook**, and **QualityControl** with its QA ledger.
- **`.claude/`** (the role files, hooks and skills), most of `qa/` and the agent tools in
  `lib/hecks/tools`.

What stays: the StaffEngineer bluebook, the Harness, the fuzzer, the gate tools (`GateRun`,
`StyleRun`, `ConformanceRun`), Tickets, `qa/settings.yml`, `qa/stress_domains` and
`qa/combination_miner`.

**Attaching by name.** These names are no longer bluebooks the gem carries: `Composer`,
`QualityControl`, `Fixer`, `Coder`, `CiPipeline`, `PipelineBoard`, `Pipeline`, `Agents`, `Triage`,
`Interviews`, `Signalbox` and `Roundhouse`. A hecksagon that attaches one is refused at boot with
`Hecks::Runtime::WiringError`:

```
attaches "Composer": the gem carries no bluebook of that name — known: Adapter, Bluebook, … To attach a vendored package, write `attaches "Composer", from: :vendor`
```

Delete the `attaches` line, and run the work it did from a Switchyard checkout. Their commands
(`Landing.finish!`, `SendTrain.board!`, `Shipment.ship!`, `hecks interviews …`,
`hecks quality_control …` and the rest) are unknown to the `hecks` launcher, so a script that runs
them runs Switchyard's launcher instead.

**`Harness::Run#open_role`.** The gem carries no role files, so `open_role(role, root:)` takes the
checkout whose `.claude/agents` holds them. Without `root:` it raises `Harness::Roles::Unbriefed`
(`no role file for <role> at <path>`).

**The resident's cap.** `max_residents` is 8 when the world sets none; it no longer comes from a
machine profile. Write `max_residents:` on the world's `resident` line if 8 does not suit.

- **Find them:** `grep -rnE 'attaches "(Composer|QualityControl|Fixer|Coder|CiPipeline|PipelineBoard|Pipeline|Agents|Triage|Interviews|Signalbox|Roundhouse)"' --include='*.hecksagon' .`,
  and search scripts and CI jobs for `Landing.`, `SendTrain.`, `Shipment.`, `interviews` and
  `quality_control`.

## Not in 8.0

- **The revision layout's code is not merged into `Postgres`.** `revisions true` reaches it through
  `Postgres`, but its journal, dialect, events and sagas are still the `PostgresEra` class's own
  (ADR 0182, "As built"). That change touches no hecksagon, world or stored name, so it can land in
  a minor.
- **Renaming the stored `hecks_*era*` names.**
