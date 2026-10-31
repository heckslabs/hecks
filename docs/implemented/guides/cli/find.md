# find

Read the code. Use it to search the checkout's text, read a file by line, or see what a file
declares.

**Status: not yet a module.** Today these are queries on `InspectionRun`. Until step 5 of
ADR 0163 moves them, use the commands below.

**Concept.** Reads change nothing. A query has no bang, so it cannot write. `search` matches a
pattern across the checkout's text files; `outline` lists what a file declares, by line.

**Example: search for a pattern**

```sh
hecks search ship
```

Lists the commands and queries whose names or descriptions match, grouped by module. For the
checkout's text, use `hecks query Codebase.search pattern.value=<text>`.

**Example: read a file by line range**

```sh
hecks query Codebase.read_source path.value=lib/hecks/cli.rb from.value=1 to.value=30
```

**Example: see what a file declares**

```sh
hecks query Codebase.outline path.value=lib/hecks/cli.rb
```
