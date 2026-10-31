# evolve

Change the language and rewrite what depends on it. Use it when a word of the language is
added, renamed or retired, and the tables and generated code must follow.

**Concept.** The language is a set of keyword rows and argument rows, each in one of a few
states: proposed, admitted, deprecated or retired. A row reaches the generated tables only once
it is admitted. Projections write those tables from the rows; generated output is never edited
by hand.

**Example: propose a keyword**

```sh
hecks LanguageRun.propose! word.value=<word> context.value=<context>
```

The row is entered as proposed. It reaches no projection until it is admitted.

**Example: admit it**

```sh
hecks LanguageRun.admit! word.value=<word> context.value=<context>
```

Moves the row to admitted, and makes it available to the projections.

**Example: project the parser table after a change**

```sh
hecks LanguageRun.project_parser_table!
```

Writes the Rust parser's keyword table from the rows, so the generated code follows the language.
