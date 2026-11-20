# find

<!-- prose anchor="Concept" purpose="concept" supports="doc:docs/decisions/0163-hecks-is-one-context-in-task-modules-and-a-bang-is-the-only-sign-of-a-write.md code_file:lib/hecks/hecks/find/find.bluebook" -->
Read the code. Use it to search the checkout's text, read a file by line, or see what a file
declares.

**Status: not yet a module.** Today these are queries on `InspectionRun`. Until step 5 of
ADR 0163 moves them, use the commands below.

**Concept.** Reads change nothing. A query has no bang, so it cannot write. `search` matches a
pattern across the checkout's text files; `outline` lists what a file declares, by line.

<!-- prose anchor="Examples" purpose="tutorial" mentions="command:Codebase.search command:Codebase.read_source command:Codebase.outline" supports="code_file:lib/hecks/hecks/find/find.bluebook" -->
**Example: search for a pattern**

```sh
hecks search ship
```

Lists the commands and queries whose names or descriptions match, grouped by module. For the
checkout's text, use `hecks Codebase.search pattern.value=<text>`.

**Example: read a file by line range**

```sh
hecks Codebase.read_source path.value=lib/hecks/cli.rb from.value=1 to.value=30
```

**Example: see what a file declares**

```sh
hecks Codebase.outline path.value=lib/hecks/cli.rb
```

## Commands

Every command and query this module lists for a person, generated from its bluebook. `hecks find` prints the same list.

<!-- generated:begin cli section=find -->
### Codebase

A read of the checkout's text files, answered without changing anything.

- `hecks Codebase.search <pattern> [paths=] [top=]`: The lines of the checkout's text files that match a pattern, as path:line: text.
- `hecks Codebase.read_source <path> [from=] [to=] [top=]`: The numbered lines of one file of the checkout, whole or from one line to another.
- `hecks Codebase.outline <path>`: What a file declares, by line: each construct of a bluebook, each definition of Ruby.
- `hecks Codebase.declaration <name> [kind=] [paths=] [show=]`: Where a named construct is declared across the corpus, as path:from-to, with its text on request.

### Index

A full-text index over the records the repository keeps (work items, findings, decisions), answered without a model and without changing them.

- `hecks Index.find <words> [kind=] [top=]`: The best matches for some words among work items, findings and decisions, as kind, id and a one-line snippet, ten at most; a kind narrows it to one sort of record.
<!-- generated:end cli -->
