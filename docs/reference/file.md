# File

Words available at the top of a file.

*The tables on this page are generated from the language's own
Syntax chapter (`lib/hecksagain/language/bluebook/syntax.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*

## bluebook

<!-- generated:begin word=bluebook -->
`bluebook name, version: do ... end` — opens a `Bluebook` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
| `version:` | text | false | version |
<!-- generated:end -->

Opens a `.bluebook` file — one domain's aggregates, value objects, and rules, described as data. `version:` pins a contract version to the whole chapter; most domains declare none, and an unversioned chapter is always the "current" one for its name. A chapter may be split across several files that all open `Hecks.bluebook "Name" do ... end` — their declarations accumulate into one domain rather than the last file replacing the first.

## hecksagon

<!-- generated:begin word=hecksagon -->
`hecksagon domain do ... end` — opens a `Hecksagon` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | domain |
<!-- generated:end -->

Opens a `.hecksagon` file — how THIS deployment wires an already-declared bluebook: which adapter persists each aggregate, which events it takes from outside, which driving ports it exposes. Says WHERE, never WHAT; see the Hecksagon reference page for the vocabulary inside.

## world

<!-- generated:begin word=world -->
`world domain do ... end` — opens a `World` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | domain |
<!-- generated:end -->

Opens a `.world` file — the values THIS deployment's adapter bindings actually need (a realm, an optional pinned `latest` version, and per-binding settings like a database URL). A sibling of the bluebook, never part of it: the same domain runs in many worlds. See the World reference page.

