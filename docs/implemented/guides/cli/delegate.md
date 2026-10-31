# delegate

Hand work to a background session. Use it when a task is long or separate, and you want it
run and tracked, not run in your own session.

**Concept.** A dispatch starts one background Claude session in a directory, with a brief. The
run is recorded, so you can ask later whether the session is still working, and tidy the run
once it has finished.

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
