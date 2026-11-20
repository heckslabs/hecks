# check

<!-- prose anchor="Concept" purpose="concept" mentions="command:GateRun.gate!" supports="doc:docs/decisions/0163-hecks-is-one-context-in-task-modules-and-a-bang-is-the-only-sign-of-a-write.md code_file:lib/hecks/hecks/check/check.bluebook" -->
Is it right? Gates, model checks, style, inspection and the audit of a journal. Use it before a
change leaves your checkout.

**Concept.** A gate is a named stage of checks, such as `quick`. `GateRun.gate!` runs every
check of a stage, or only the ones you name, and keeps whether the gate is green. A check that
fails names what it found.

<!-- prose anchor="Examples" purpose="tutorial" mentions="command:GateRun.gate! command:ModelCheckRun.model_check!" supports="code_file:lib/hecks/hecks/check/check.bluebook" -->
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

## Commands

Every command and query this module lists for a person, generated from its bluebook. `hecks check` prints the same list.

<!-- generated:begin cli section=check -->
### GateRun

One run of a stage's checks: every check of the stage, or the ones named.

- `hecks GateRun.gate! <stage> [only=]`: Run every check of a stage, or the ones named, and keep whether the gate is green

### ModelCheckRun

One static analysis over domains' models, and what it found: a check's history.

- `hecks ModelCheckRun.model_check! [<domains>] [profile=] [--strict]`: Check domains for dead states and unreachable steps, and keep the verdict

### ConformanceRun

One check that the engines, the reference docs and the argument gates agree with the language.

- `hecks ConformanceRun.check_engine_agreement!`: Check that the query engines route every comparator through the one shared implementation
- `hecks ConformanceRun.measure_doc_coverage!`: Check that every live word of the language has prose and a running example in the reference
- `hecks ConformanceRun.check_shape_ledger! --confirm`: Check that no bluebook's storage shape moved in a way that is neither additive nor covered by a translation edge, and rewrite the ledger when confirmed
- `hecks ConformanceRun.check_command_names!`: Check that every launcher name a workflow, hook, gate row, spec or guide invokes is one the launcher accepts
- `hecks ConformanceRun.check_workflow_pagination!`: Check that no workflow counts or waits on the items of a GitHub list call that returns only its first page
- `hecks ConformanceRun.argument_gate_matrix! --confirm`: Generate the argument-gate ordering matrix; rewrite it and its fixtures only when confirmed
- `hecks ConformanceRun.report_role_shadow! <domain>`: List each role-gated command and each policy or saga reaction to one in a domain, which a caller that states no role would be refused once refusal is on

### StyleRun

One check or fix of comment style, or one document written with its keys in order.

- `hecks StyleRun.check_comments! <paths> [only=]`: List every comment that breaks the Ruby style guide
- `hecks StyleRun.fix_comments! <paths> [only=] --confirm`: Rewrite the mechanical Ruby comment violations
- `hecks StyleRun.shorten_value_objects! [<paths>] --confirm`: Rewrite every bluebook value object block that only wraps one plain value as the shorthand
- `hecks StyleRun.write_comment_baseline! [<paths>] --confirm`: Record every long comment block as tolerated, for lib/hecks unless paths are named
- `hecks StyleRun.check_comments_unchanged! <ref> [paths=]`: Prove an edit was comment-only: no file's code differs from the ref
- `hecks StyleRun.check_rust_comments! <paths> [only=]`: List every comment that breaks the Rust style guide
- `hecks StyleRun.fix_rust_comments! <paths> [only=] --confirm`: Rewrite the mechanical Rust comment violations
- `hecks StyleRun.canonicalise! <file>`: Write a JSON document with every object's keys sorted
- `hecks StyleRun.report_comments <paths> [only=] [top=] [--json]`: The Ruby comment violations, as summary tables, a list or JSON.
- `hecks StyleRun.report_rust_comments <paths> [only=] [top=] [--json]`: The Rust comment violations, as summary tables, a list or JSON.

### InspectionRun

One inspection of the Ruby by flog, flay, reek or rubycritic.

- `hecks InspectionRun.flog! [<paths>] [top=]`: Rank the Ruby methods by complexity, worst first
- `hecks InspectionRun.flay! [<paths>] [top=]`: Find Ruby code that is copied or nearly copied
- `hecks InspectionRun.reek! [<paths>] [top=]`: List the design smells in the Ruby
- `hecks InspectionRun.rubycritic! [<paths>] [top=]`: Write the combined quality report, with git churn

### Audit

One walk of a domain's journal chain from its latest seal, and whether every digest held.

- `hecks Audit.verify! <domain>`: Walk a domain's journal chain from its latest seal and say whether it was altered
<!-- generated:end cli -->
