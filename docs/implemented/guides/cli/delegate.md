# delegate

<!-- prose anchor="Concept" purpose="concept" supports="doc:docs/decisions/0163-hecks-is-one-context-in-task-modules-and-a-bang-is-the-only-sign-of-a-write.md code_file:lib/hecks/hecks/delegate/delegate.bluebook" -->
Hand work to a background session. Use it when a task is long or separate, and you want it
run and tracked, not run in your own session.

**Concept.** A dispatch starts one background Claude session in a directory, with a brief. The
run is recorded, so you can ask later whether the session is still working, and tidy the run
once it has finished.

<!-- prose anchor="Examples" purpose="tutorial" mentions="command:AgentRun.dispatch! command:AgentRun.check! command:AgentRun.tidy!" supports="code_file:lib/hecks/hecks/delegate/delegate.bluebook" -->
**Example: hand a brief to a background session**

```sh
hecks AgentRun.dispatch! repo.value=~/Projects/hecks brief.value="Run the cli specs and report"
```

The repository must be a trusted workspace.

**Example: ask whether it is still working**

```sh
hecks AgentRun.check! to=<run>
```

**Example: remove a finished run**

```sh
hecks AgentRun.tidy! to=<run>
```

Removes the finished session of the run, unless it is unfinished or a person took it over.

## Commands

Every command and query this module lists for a person, generated from its bluebook. `hecks delegate` prints the same list.

<!-- generated:begin cli section=delegate -->
### AgentRun

One brief handed to a background Claude session: started and tracked, or refused with the reason.

- `hecks AgentRun.dispatch! [<repo>] brief= [agent=] [works_as=] [work=] [parent=]`: Hand one brief to a background Claude session working in a directory
- `hecks AgentRun.check! <to>`: Read the state a started session's job is in, and record it when it changed
- `hecks AgentRun.tidy! <to> now=`: Remove the finished session of one run, unless it is still working, a coder waiting on a person, or taken over
- `hecks AgentRun.release! <to>`: Review a kept run at the next reap, without waiting for its retry time
- `hecks AgentRun.answer! <to> answer= [step=] [verdict=] [--resuming]`: Answer a session that has not ended: deliver to a working one, resume an idle one
- `hecks AgentRun.rebind! <to> session=`: Move a started run to a named live session that no other started run holds
- `hecks AgentRun.retire! <to>`: Close a started run whose session is gone, so the ledger stops listing it as started
- `hecks AgentRun.working`: Every started run whose session is not waiting on a person, oldest key first; its standing is working.
- `hecks AgentRun.blocked`: Every started run whose session waits on a person, oldest key first.
- `hecks AgentRun.answering`: Every started run that answers a blocked run's question, its work the run that asks.

### SessionSweep

One check of every started run's session: each change of state is recorded on its run.

- `hecks SessionSweep.check_all!`: Check every run whose session was started and is not known to have ended

### Dispatch

One filling of the Work queue: the planned Work items that start a session now, and why each other waits.

- `hecks Dispatch.fill! <repo> [budget_minutes=] [only=] --confirm`: Choose the planned Work items that start a session now and, with confirm, start them; without it, say what would start
- `hecks Dispatch.settle! <repo>`: Check the started sessions and finish the Work item of each that is done, or yield the Work item of one that stopped
- `hecks Dispatch.preview [<repo>] [budget_minutes=] [only=]`: What a filling would start now and why each other waits, read without filling: the same report as `Fill`, with no record and no start.

### MergeWindow

One merge window: opened to let a train merge without competing work, closed when it has merged or by hand.

- `hecks MergeWindow.open! <reason> opened_by=`: Open a merge window: pause the fill and quiet the pipeline until the window closes
- `hecks MergeWindow.close! <to>`: Close the merge window so the fill runs again

### Machine

One reading of the machine, and the crossings of a mark that it heard.

- `hecks Machine.busiest`: Which process classes use the CPU and whose child they are: each class's count, summed CPU percentage and the background session whose shell owns it, busiest first. Read-only: it stops no process and no session.

### PlainSession

A Claude session started outside a dispatched run, which the operator may remove once it is finished.

- `hecks PlainSession.remove! <condition>`: Remove a finished session that waits on nobody
- `hecks PlainSession.retire! <session> [reason=]`: Retire a session bound to no run, so the fleet does not settle and re-claim it

### SessionCleanup

One cleanup of the Claude sessions: only the session of a dispatched run that finished done, with no person in it and nothing unsaved in its worktree, is removed; every other session is kept with the reason.

- `hecks SessionCleanup.remove_safe! --confirm`: Remove the sessions of dispatched runs that finished done and are safe to remove, and report each one kept with the reason; refused without confirm
- `hecks SessionCleanup.removable`: Every Claude session with whether it is safe to remove and, when not, why: no dispatched run holds it, its run is not finished done, it is not listed done, a person spoke in it, or its own worktree has uncommitted files or commits origin lacks. Reads only.

### Question

One question a blocked run asks the orchestrator: asked, seated with an orchestrator run that answers it, then closed when the run is answered or escalated as the owner's.

- `hecks Question.escalate! <to>`: Hand a seated question to the owner, unanswered, and free its seat

### AnswerDesk

The seats of the orchestrator runs that answer questions, at most two taken at once.

- `hecks AnswerDesk.desks`: The desk and how many of its seats are taken.
<!-- generated:end cli -->
