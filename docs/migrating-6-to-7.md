# Migrating from Hecks 6.x to 7.0

This is the one page to follow when you take 7.0.0. It lists every break in the order a project
meets them. Each item gives the old spelling, the new one and how to find what needs changing.
The [CHANGELOG](../CHANGELOG.md) entry for 7.0.0 has the full wording and the reasons. Where this
page and an older note disagree, this page is right.

## Do these first

1. Pin `hecks` 7.0.0 and run `hecks doctor`.
2. Re-run `hecks Launch.project_cli!` so your generated launchers stop handing legacy names to the
   old dispatcher. A launcher you do not regenerate keeps working until you do.
3. Search your scripts, CI jobs, hooks, Makefiles and docs for the names in sections 1, 2 and 3
   and change them.
4. If your world renamed an aggregate or a domain with `formerly_known_as`, do section 4 before
   you deploy, not after.
5. If your domain persists through `PostgresEra`, read section 5 before you deploy.
6. Run `hecks ModelCheckRun.model_check!` and your own specs.

Maintainers of a Hecks checkout also read section 7.

## 1. Launcher commands

A command is written with `!`, and a query is written without it. The legacy positional forms
are refused: they exit 2 and print the spelling to use. `Hecks::CLI` is removed.

| 6.x | 7.0 |
|---|---|
| `hecks run …` | `hecks Operation.run! …` |
| `hecks docs …` | `hecks introspection.docs …` |
| `hecks narrate …` | `hecks introspection.narrate …` |
| `hecks ir …` | `hecks introspection.ir …` |
| `hecks stores …` | `hecks introspection.stores …` |
| `hecks model_check …` | `hecks ModelCheckRun.model_check! …` |
| `hecks smoke_test …` | `hecks Operation.smoke_test! …` |
| `hecks project_diagrams …` | `hecks introspection.project_diagrams domain=… bluebook=…` |
| `hecks project_cli` | `hecks Launch.project_cli!` |
| `hecks mcp` | `hecks mcp!` |

`init` and `interview` are unchanged. A bang-less spelling of any command (`Operation.run`,
`GateRun.gate`) exits 2 and names the `!` spelling. Queries are unaffected.

Exit statuses are now fixed: 0 when the launcher answers, 1 when a command is refused or fails,
2 for a usage mistake. A script that treated every non-zero as "refused" should tell 1 from 2.

New in 7.0 and worth knowing while you are in there: `--plan` on any bang command lists what it
would write and changes nothing, and `--json` on the listing.

## 2. Renamed aggregates and commands

| 6.x | 7.0 |
|---|---|
| `PullRequest` (`merge`) | `ReviewRequest` (`take`) |
| `Commit` | `Revision` |
| `Checkout` (`log`) | `Workspace` (`history`) |
| `PushTrain` (`push`) | `SendTrain` (`send`) |
| `push_train.board!` | `send_train.board!` |

Each renamed aggregate keeps its old name in `formerly_known_as`, and its storage table keeps its
old name, so stored rows read under the new name. Old spellings resolve through a rename table
and print the new spelling once to stderr. The table resolves through 8.0, so change your calls
before then.

Two groups of commands moved: `Server` now holds `present`, `compose`, `preview`,
`serve_query_ir_mcp` and `serve_mcp` (from `CorpusRun` and `Launch`), and `Codebase` holds
`search`, `read_source`, `outline` and `declaration` (from `InspectionRun`).

## 3. Words in a bluebook, a world and a hecksagon

- **"Chapter" is gone** (ADR 0134). No old name answers and none warns.

  | 6.x | 7.0 |
  |---|---|
  | `Hecks::Bluebook::Chapter` | `Hecks::Bluebook::Declaration` |
  | `Hecks::Chapters` | `Hecks::FrameworkBluebooks` |
  | `Registry#forget_chapter` | `Registry#forget_bluebook` |
  | `hecks-parse chapter --chapter` | `hecks-parse bluebook --bluebook` |
  | launcher keys `chapters`, `maintainer_chapters` | `bluebooks`, `maintainer_bluebooks` |
  | `chapter=` on `introspection.statements`, `project_diagrams`, `glossary` | `bluebook=` |
  | Composer `chapter_name` | `bluebook_name` |
  | site table `Editor` and `Payload` rows' `chapter`, `chapter_roles` | `bluebook`, `bluebook_roles` |

  Change your hecksagons, world, site table and scripts. Search for `chapter` and
  `Chapters.load!`.
- A bluebook names its modules with `domain_module "Name" do … end`.
- A command declares who it is for with `audience :person, :agent, :ci, :record`.
- An aggregate that is a run declares `kind: "Run"`.
- `ReleasePR` carries `verdict`, not `state`.

## 4. `formerly_known_as`, `stored_as` and `formerly`

This is the break most likely to lose you data if it is skipped, so do it before you deploy.

- A table or file name an aggregate's rows sit under now lives in the world:
  `stored_as Revision: "commit"` at the top level.
- A domain's former name lives in the `persisted_by("PostgresEra")` block: `formerly "Old"`.
- The bluebook's `formerly_known_as` still works as a fallback, warns once per process, must
  agree with the world when both are given, and leaves the grammar in a later major release.
- A table adapter now refuses to start an empty table beside rows of an earlier name, naming the
  table. If you see that refusal, your `stored_as` is missing or wrong.

To move an aggregate's name, run `exe/hecks codemod_run.move_former_name!` (it prints what it
would change; add `--confirm` to write), or add the `stored_as` line by hand. To move a domain's
name, put the line in the world's `persisted_by("PostgresEra")` block as `formerly "Old"`.

A domain-level `formerly_known_as` no longer renames at boot. A boot under the new name refuses
by name until `exe/hecks era.rename_domain! --confirm` has moved the eras, held texts,
attestations, journal, sequence, partitions and heads in one transaction. A project that renamed
its domain and has not yet booted under the new name runs `era.rename_domain` first.

## 5. Stores and eras

Only a project on `PostgresEra` (or one that reads the era tools) meets these.

- **A boot over a held shape that differs from the current one refuses unless a recorded
  translation covers it.** The message reads `cannot boot <Domain>: no translation edge covers
  it …` with both labels and the remedy. Before a breaking shape change, write the edge
  (`era.scaffold_translation`) and mint it with the release mint, then deploy. An edge or a
  provably additive move covers a boot.
- **An era is its stored projection and hash; held text is audit-only.** An era with no stored
  projection is read through its held text only when that text hashes to the era's stored hash;
  otherwise it is refused by name.
- **`hold_first` grants the app role** from the world's `role:` setting. A world with no `role:`
  grants nothing, as before.
- **`hecks deploy provision` holds era 1 in a new tenant schema before it boots.** A boot of an
  empty schema no longer holds one implicitly (ADR 0168). Eras of an existing schema are never
  touched.
- **Tooling domains are no longer in the shape ledger.** `lib/hecks/hecks/shapes.json` holds only
  bluebooks whose committed persistence is an era adapter, and framework members such as
  Governance that clients persist. If you relied on a tooling domain's ledger entry or edge,
  remove the reference.
- A world can declare `disposable_ledger true` for a tooling ledger. It is never for client data.

## 6. Runtime behaviour that changed

- **The reaction depth limit is five on both runtimes.** Five nested reactions below the root
  command run and the sixth is refused. Rust used to refuse the fifth, so a chain of exactly five
  now runs on Rust. The model check's `deep_reaction_chain` warns only for a chain longer than the
  limit.
- **An adapter's programming error is raised, not refused.** `NameError`, `NoMethodError`,
  `TypeError`, `FrozenError` and `ScriptError` from an adapter used to be announced as the ask's
  refuses event. They now raise, and a policy's ask records them as a warned defect.
  `ArgumentError` still refuses. If a test expected a refusal from one of these, fix the adapter.
- **The Rust host's era table gains an `edge jsonb` column** and stores `held_projection` on its
  mints, so Ruby can read a database the Rust host holds.
- **`Work.plan!`** takes an optional `area` and its `detail` defaults to empty.

## 7. Working in a Hecks checkout

Only people who push to a Hecks checkout, or run its tooling, need this section.

- **A plain `git push` of `main` is refused.** Board the push train:
  `exe/hecks SendTrain.board! --confirm`. Branch and tag pushes are unchanged. An agent never
  sets the owner's override, `HECKS_OWNER_PUSH=<reason>`.
- **A push of `main` runs the quick gate and nothing else.** The `unguarded_push` stage, the
  push-specs rehearsal step and the `meta_domain_coverage` and `everyday_names` gate rows are
  deleted; drop the names from any script that mentions them. Fuzzing, the push-chain specs,
  `command_names` and `workflow_pagination` run in CI and nightly, and a red one blocks promotion
  to `stable`, never the push. `send_train.board! --confirm full_gate.value=true` runs the whole
  `pre_push` stage on request.
- **The full spec suite is CI-only.** `test_suite_run.run_suite!` is refused outside CI, and
  `run_spec_files!` and `run_impacted_specs!` refuse or cap a call over `spec_files_limit`. Run the
  quick gate and named specs locally.
- **The push train runs in Memory and mints nothing.** `MintBeforeCarry`, `ClearWhenMinted`,
  `CarryWhenCleared`, `RecordTheRefusedMint`, the `Clear` command and `BoardingCleared` are
  retired, along with the train's database. A client that read the train's database reads git.
- **Deleted:** `Work.overdue`, the `full` rehearsal scope, the red-main watch, the Era proof
  workflow and gate, `GithubCiWebhook`, and the `Watch` lanes' issue filing. The quick scope is
  the push gate.
- `landing.land!` refuses a branch that changes files another started row holds, or a branch
  behind `origin/main`.

## What does not change

- Bluebooks, worlds and hecksagons that use none of the names above load as before.
- Queries keep their spelling.
- Held bluebooks are unchanged by the shape-ledger change.
- Branch and tag pushes, and the `.behaviors` and example formats, are unchanged. A sentence-form
  example step can now give a value made of parts (`price 1200 cents and size "large"`); see
  [sentence-form.md](sentence-form.md).

## If something refuses

Refusals carry a stable code in brackets (`[unknown_command]`, `[not_found]`) and name the fix.
`hecks doctor` checks the environment, and `Workspace.where` shows each bluebook's store and the
reason for it.
