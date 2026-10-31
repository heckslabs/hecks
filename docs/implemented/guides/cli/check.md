# check

Is it right? Gates, model checks, style, inspection and the audit of a journal. Use it before a
change leaves your checkout.

**Concept.** A gate is a named stage of checks, such as `quick`. `GateRun.gate!` runs every
check of a stage, or only the ones you name, and keeps whether the gate is green. A check that
fails names what it found.

**Example: run the quick gate**

```sh
hecks GateRun.gate! stage.value=quick
```

Each check of the quick stage runs and reports `ok` or `fail` as it finishes.

**Example: find a line in the code**

```sh
hecks search search
```

Lists the commands and queries whose names or descriptions match, grouped by module.

**Example: check that a domain's model has no dead states**

```sh
hecks ModelCheckRun.model_check! domains.value=examples/banking
```

Reports dead states and unreachable steps, and keeps the verdict.
