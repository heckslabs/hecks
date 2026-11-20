# deliver

<!-- prose anchor="Concept" purpose="concept" supports="doc:docs/decisions/0163-hecks-is-one-context-in-task-modules-and-a-bang-is-the-only-sign-of-a-write.md code_file:lib/hecks/hecks/deliver/deliver.bluebook" -->
Take finished work into the shared line. Use it to commit a change, land a branch on local
main, and send main onward.

**Concept.** A checkout is one working copy of the repository. A landing merges a worktree's
branch onto local main, never forced and never pushed. A push train sends local main in turn,
behind whatever was pushed before it.

<!-- prose anchor="Examples" purpose="tutorial" mentions="command:Workspace.status command:Landing.land! command:Shipment.ship! command:Shipment.rejudge!" supports="code_file:lib/hecks/hecks/deliver/deliver.bluebook" -->
**Example: see where your work stands**

```sh
hecks Workspace.status
```

Prints the checkout's branch, whether it is a linked worktree, and where it stands against main.

**Example: land a branch on local main**

```sh
hecks Landing.land! --confirm checkout.value=/path/to/worktree branch.value=my-branch
```

Fast-forwards main when it can, and makes a merge commit when main has moved.

**Example: run the gate, land and send finished work**

```sh
hecks Shipment.ship! --confirm branch.value=my-branch checkout.value=/path/to/worktree
```

Starts the gate-and-board saga for the branch: the checkout's own gate judges it, and a green
answer leaves it ready to land. `hecks Shipment.rejudge!` asks the gate again after a refusal.

Run `hecks deliver` for every command in this module, grouped by aggregate.

## Commands

Every command and query this module lists for a person, generated from its bluebook. `hecks deliver` prints the same list.

<!-- generated:begin cli section=deliver -->
### Workspace

A look at how this copy of Hecks is set up: its settings, its stores and whether it can run here.

- `hecks Workspace.config [<domain>]`: What this copy resolves for each setting that can come from a variable, its own world or a default, and which one supplied it.
- `hecks Workspace.doctor [<domain>]`: Whether this checkout can run Hecks here: overlay files parse, the stores answer, the toolchain pin matches, and what this worktree cannot see.
- `hecks Workspace.where [<domain>]`: Where this checkout's domain resolves: the store each bluebook uses and why, the audience and environment with their reasons, and any overlay file this worktree lacks.

### LandingPace

A measure of the landings a ledger recorded: how many a day, and how long a change waited.

- `hecks LandingPace.pace [<days>]`: Landings per UTC day over the last days (14 unless given), the refusals, and the wait from ready to landed as median, 90th percentile and longest. A change is ready at the first request to land it (submit, finish, land, carry or train) that names its branch or is the landing's own run, since that branch last landed; it is landed at BranchLanded.

### Restoration

The changed files of a checkout that already match origin/main, restored, or declined with the reason.

- `hecks Restoration.make! [<checkout>]`: Restore each changed file of a checkout that already matches origin/main, and leave every other file alone

### ShallowCheck

CI's failing checks run in a depth-1 clone of a branch: passed or skipped, or refused with the spec and its first failure line.

- `hecks ShallowCheck.run! [<checkout>] [branch=] [onto=]`: Run CI's failing checks in a depth-1 clone of a branch when it changes something they read, refusing with the spec and its first failure line
- `hecks ShallowCheck.switch! [<checkout>] state=`: Turn the shallow check on or off for the whole repository

### EarlyCi

One branch pushed as ci/<branch> with a never-merged draft, by a landing or by its coder before hand-off, and what CI said of its head.

- `hecks EarlyCi.request! <branch> sha= checkout= [work=] [--clean]`: Ask CI to check a coder's branch at its head, pushed as ci/<branch>, before the coder hands it off
- `hecks EarlyCi.retry! <to> sha= [--clean]`: Ask CI again for the branch at its new head, after a red run or a run that could not be read

### SendTrain

One push of a checkout's branch, taken in turn: carried by an earlier push, pushed, or refused.

- `hecks SendTrain.board! [<branch>] [remote=] [checkout=] [commit=] [--full-gate] --confirm`: Push this checkout's branch once the push ahead of it lands, unless that push already carried it
- `hecks SendTrain.survey! [<remote>] [checkout=]`: List every checkout under a directory whose branch has commits its remote does not
- `hecks SendTrain.watch! <to>`: Look at each queued boarding's pull request, and record any that merged or ended with failed checks

### PushOutcome

How one boarding of the push train ended, as the boarded checkout records it: pushed, carried or faulted.

- `hecks PushOutcome.record! <checkout> [branch=] outcome= [pushed=] [commits=] [report=]`: Record how one boarding of the push train ended, in the checkout that boarded it

### Shipment

One request to gate, land and board a branch: the gate-and-board saga starts on it.

- `hecks Shipment.ship! <branch> checkout= [confirm=]`: Start the gate-and-board saga for a branch: ask its checkout's gate, land on main, board the push train
- `hecks Shipment.rejudge! <to>`: Ask the checkout's gate to judge a shipment again, after a gate that refused it

### Integration

One step of integrating main (verify, board, observe CI) or one advance of the open runs, and how it ended.

- `hecks Integration.advance! --confirm`: Dispatch the next step of every open integration run, once: verify a landed run, board a verified one, observe a pushed one
- `hecks Integration.schedule! --confirm`: Ask for the launchd job that beats the clock once a minute to be written and loaded; unconfirmed, it says what it would write
- `hecks Integration.unschedule! --confirm`: Ask for the launchd job that beats the clock to be unloaded and removed; unconfirmed, it says what it would remove
- `hecks Integration.verify! <landed> [checkout=] [--retried] [--revert]`: Verify a landed commit in a clean detached copy of local main: the quick gate, the specs its changes touch, the command names, the CI pipeline and the generated corpus
- `hecks Integration.board! <landed> [checkout=] --confirm`: Push a verified commit of main by boarding the push train in its own copy, refusing an agent's trailer, a version change or a release approval
- `hecks Integration.observe! <landed> [checkout=] [--pulled]`: Read the CI run of a pushed commit on GitHub: passed, failed with the failed jobs, or still running

### ReviewRequest

One pull request opened or merged on GitHub, and what GitHub answered.

- `hecks ReviewRequest.open! <branch> [base=] [confirm=]`: Open a pull request from a branch onto a base, and keep the number and URL GitHub gives it
- `hecks ReviewRequest.take! <number> [confirm=]`: Merge an open pull request by its number, in a merge commit; never with an admin override
- `hecks ReviewRequest.edit! <number> [title=] [body=] [confirm=]`: Edit the title or body of an open pull request by its number; never its branch, merge or state
- `hecks ReviewRequest.status <number>`: The state of one pull request on GitHub: its number, state, URL and checks, as text.
- `hecks ReviewRequest.timeline <number>`: Who merged a pull request, who turned auto-merge on or off, who closed, reopened or was asked to review it, and when: read from its timeline on GitHub, oldest first. Nothing is changed.

### BoardingHold

One hold of local main for a boarding: held, or refused.

- `hecks BoardingHold.hold! [<checkout>] [owner=] [reason=]`: Hold local main for the boarding of the commit it names now: landings onto main are refused until a release or the window ends
- `hecks BoardingHold.status [<checkout>]`: Whether local main is held for a boarding: the commit, owner, reason and age, or that the hold expired or is absent.

### BoardingRelease

One lifting of the hold on local main: released, or refused.

- `hecks BoardingRelease.release! [<checkout>]`: Lift the hold on local main, whoever took it; a lift with nothing held is a no-op

### LandingReview

One landing's wait, after its gates, for the reviewer's verdict on its tip: cleared when clean; otherwise refused by name when enforced, or landed anyway when shadowed.

- `hecks LandingReview.landing_reviews`: Every landing's wait for review, by tip: its mode, the verdict once judged, and whether it was cleared, refused or shadowed.
<!-- generated:end cli -->
