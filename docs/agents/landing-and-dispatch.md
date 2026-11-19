# Landing, the red flag and dispatch

Read this before you land a branch, work while main is red, inspect an era or touch the QA
dispatcher. `CLAUDE.md` holds the rules every session needs; this holds the detail.

## The red flag

A red main stands a **red flag** (`RedFlag`, `lib/hecks/hecks/redflag/redflag.bluebook`): a CI run of main that completes red raises it (`Integration.CiFailed`, or `exe/hecks RedFlag.sync! run.value=<id>`), and one that completes green lowers it. While it stands, `Landing` and `SendTrain` refuse by name (`main is red: flag <id>`) everything except the fix of a red-* Work item (exe/hecks tickets Work.undone lists them): a branch named for the Work item lands and its tip is the one commit the train boards. A session listens with `exe/hecks Operation.follow domain.value=Hecks aggregate.value=RedFlag from_now=true wait=600` (RedFlagRaised, RedFlagRunNoted, RedFlagCheckedIn, RedFlagCleared), says it helps with `exe/hecks RedFlag.check_in! run.value=<id> session.value=<name> taking.value=<Work item or cause>`, and resumes on RedFlagCleared; `exe/hecks RedFlag.status` prints the flag, the red time and who is helping. Everything else lands locally with landing.land! once the flag is down.

## Landings, era inspection and the QA dispatcher

Each command's `--help` says what it takes; this names where they live. **Landing and the queue:**
`Landing.submit!` hands a branch to a landing job of its own and returns at once: the job runs `Landing.carry!`
(a finish that keeps the worktree) from the main checkout, logs to `.git/hecks-landings/<branch>.log`, reports
`BranchLanded` or `LandingRefused`, and a conflict or a red gate plans the finished Work item again with the
reason. A coder's `coder Submission.submit!` starts it.
`landing.finish!` (rebase onto local `main`, quick gate, land, tidy) and `landing.land!` take no lock and wait
for no other landing: each moves `main` by a compare-and-swap, only if it still points where the landing
started. A finish that finds `main` moved rebases and runs the gate again, so only a judged commit lands; after
five lost tries it is refused (`main moved 5 times while <branch> was landing`) and a landing job runs it again.
Only `landing.train!` still takes a place in the old line, whose limits are the world's `landing "Queue"`
(`hecks.world`). `push_rehearsal.rehearse!` runs the stages of its scope (`RehearsalScope` rows in the Vocabulary
bluebook: `quick`, the default and the push gate, and opt-in `deep` which adds the specs the changes touch) on local `main` and `push_rehearsal.due` says whether a push is due
(`rehearse/rehearse.bluebook`); `test_suite_run.run_spec_files!` and `run_impacted_specs!` run named or
impacted specs through the launcher. Branch worktrees through `LinkedTree.add!`, which pulls `main` first.
**Era inspection:** `schema_revision.boot_resolution`, `schema_revision.mint_plan` (every guard a mint runs, read-only),
`schema_revision.event_trace`, `schema_revision.sqlite_status` and `schema_revision.projection_audit` read without writing; `SchemaRevision.RenameDomain`
(`schema_revision.rename_domain!`) moves a renamed domain's history. The world words are `disposable_ledger`,
`stored_as` (the table an aggregate's rows keep after a rename), `formerly` (a domain's former name) and
`minting` (the command an unminted boot may write). **QA and dispatch:** `qa_quiesce.hold!`, `release!`
and `status` quiet QA for a mint; `Dispatch.Fill` starts sessions for planned Work items and
`Dispatch.Settle` finishes the rows of sessions that ended (`delegate/delegate.bluebook`). **Stalls:**
each beat runs `StallWatch.detect!` (`stall_watch/stall_watch.bluebook`), whose `StallKind` rows name an
opening event, its closing events, the minutes allowed and the fixer; each stall found is filed once
as the Work item `stall-<kind>-<subject>`, which the fill starts after red; a landed
branch finishes the Work item of the same name (or the same name without a leading `qa/`). The Tickets
world's `work_limit`, `frozen_shapes` and `session_environment` bound and equip those sessions. The
checks `command_names` and `workflow_pagination` (in the quick gate and CI) keep the names in docs, workflows and guides
resolvable and lists paged; the spec suite holds the meta-domain covered.
