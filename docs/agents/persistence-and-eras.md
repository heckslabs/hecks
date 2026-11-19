# Persistence, eras and the push train

Read this before you touch a hecksagon's persistence, a local overlay, the shape ledger, an era
or a mint. `CLAUDE.md` holds the rules every session needs; this holds the detail.

## The push train runs in Memory

The push train (`~/.claude/hecks-train`, a detached checkout) runs in Memory like every other tooling
domain: it needs no database, no local files and no mint. What must outlive a process comes from git:
the line is a lock in the repository's git directory, and a commit the remote already holds is
answered `carried`. Its mint step reports `Memory holds no eras, no mint needed`.

- Dev work needs no environment variable: Hecks is in Memory unless a local hecksagon's root
  `persisted_by "PostgresEra"` opts it in (the attached bluebooks inherit it). Do not add local
  files to a development checkout, and none by hand to the train's copy. The one exception is the
  train's generated, gitignored `hecks.local.hecksagon`, which `Train#write_overlay` writes at each
  boarding from the `KeptAggregate` rows of `lib/hecks/hecks/hecks.bluebook`: the clock chain's
  ticks are separate processes and need the Ticker kept, and a hand copy fell behind. The same rows
  write the main checkout's overlay (`exe/hecks LocalOverlay.write! root.value=<checkout>
  copy.value=main`), and a write to a kept aggregate that a checkout with a local overlay binds to
  Memory is refused by the aggregate's name.
  A linked worktree that keeps no local file of its own loads the main checkout's
  (`WorktreeBorrow`, `lib/hecks/adapters/driven/worktree_borrow.rb`), so its commands use the same dev
  databases under `~/.claude/hecks-dev`. A lent bind to an aggregate the worktree's own code does not declare is
  left out and said once, not refused; rebase onto `main` to keep it too. Nothing is lent to the spec runner (`HECKS_WRITES_LOCAL`, which
  spec_helper sets) or a `memory`/`test` environment, to a worktree with its own local file (the train),
  or from a main checkout whose local world turns on `mint_eras` or `disposable_ledger`.
  `exe/hecks workspace.where` names the borrowed checkout.
  `exe/hecks config domain.value=<dir>` prints each setting, its value and which source supplied it.
- The shape ledger (`lib/hecks/hecks/shapes.json`) holds only bluebooks whose committed persistence
  (local overlays left out) is an era adapter, and framework members such as Governance that clients
  persist. Tooling is Memory by its committed world and needs no ledger entry, edge or `--confirm`.
  Each entry holds the shape's hash and projection as of the last release mint. A shape change that only
  adds passes the quick gate and commits nothing; any other change needs a translation edge under the
  bluebook's `translations/`, and `exe/hecks conformance_run.check_shape_ledger! --wait` (no database)
  names the bluebook that has none. The ledger moves only at `exe/hecks schema_revision.release_mint!
  domain.value=<dir> --confirm`, the one mint per release (ADR 0168), which an owner runs.
  Renamed or reshaped data needs rules: `exe/hecks schema_revision.scaffold_translation domain.value=<dir>`
  writes them from the database the domain's own world names, and `schema_revision.audit_translation` checks them.
- Whether a copy may migrate its database is the `mint_eras` setting in its world
  (`persisted_by("PostgresEra") do ... mint_eras true end`, also from an overlay); `hecks config`
  reports it. An unset world refuses (`EraResolver::MINT_BY_DEFAULT` is `false`).
- A tooling ledger may opt out of eras with `disposable_ledger true` in the same block
  (`LineageManager::DisposableLedger`): an additive shape change is applied in place, any other
  moves the aggregate's rows to a dated archive table (listed in `hecks_ledger_archives`) and starts
  it empty, and a boot never refuses as unminted or superseded. Never declare it for client data.
- A boot over a store that holds eras reads a shape no era holds only when an edge or a provably
  additive move covers it; a breaking move no edge covers refuses by name (`no translation edge
  covers it`), writing nothing, and the quick gate's shape ledger check refuses it at commit time.
- After a push, the launcher's refresh moves its checkout only when it is detached and has no
  changed or untracked file; the report names the file that stops it.

## Minting an era of the QA ledger: quiet QA first

The QA loop writes to the ledger all the time, so its watermark moves between a rehearsal and the mint.
A mint window starts with `exe/hecks qa_quiesce.hold! reason.value="..." --wait` and ends with
`exe/hecks qa_quiesce.release! --wait`; `qa_quiesce.status` reports the owner, reason and age. While the
marker (`~/.claude/hecks-dev/quiesce`, stale after two hours) is fresh every `sweep.tick` step prints
`quiesced: skipped <step>` and the tick exits 0. Name yourself with `owner.value=` (or
`HECKS_QUIESCE_OWNER`); another owner's marker is not removed without `force.value=true`. The mint does
not require the flag.
