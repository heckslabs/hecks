# evolve

<!-- prose anchor="Concept" purpose="concept" supports="doc:docs/decisions/0163-hecks-is-one-context-in-task-modules-and-a-bang-is-the-only-sign-of-a-write.md code_file:lib/hecks/hecks/evolve/evolve.bluebook" -->
Change the language and rewrite what depends on it. Use it when a word of the language is
added, renamed or retired, and the tables and generated code must follow.

**Concept.** The language is a set of keyword rows and argument rows, each in one of a few
states: proposed, admitted, deprecated or retired. A row reaches the generated tables only once
it is admitted. Projections write those tables from the rows; generated output is never edited
by hand.

<!-- prose anchor="Examples" purpose="tutorial" mentions="command:LanguageRun.propose! command:LanguageRun.admit! command:LanguageRun.project_parser_table!" supports="code_file:lib/hecks/hecks/evolve/evolve.bluebook" -->
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

## Commands

Every command and query this module lists for a person, generated from its bluebook. `hecks evolve` prints the same list.

<!-- generated:begin cli section=evolve -->
### LanguageRun

One change to the language's own tables, or one reading of where its words stand.

- `hecks LanguageRun.project_model! --confirm`: Project the model's holding half from the language that declares it
- `hecks LanguageRun.project_vocabulary! --confirm`: Project the language's closed sets into the vocabulary
- `hecks LanguageRun.project_rust_vocabulary! --confirm`: Project the vocabulary tables into the Rust kernel, one enum a table
- `hecks LanguageRun.project_refusal_wording! --confirm`: Project the refusal template table, a second name of ProjectRustVocabulary
- `hecks LanguageRun.project_reserved_names! --confirm`: Project the Rust and Cargo reserved words into the codegen and build crates
- `hecks LanguageRun.project_parser_table! --confirm`: Project the Rust parser's keyword table
- `hecks LanguageRun.project_phrase_table! --confirm`: Project the Rust parser's sentence table from the Sentence bluebook's phrase rows
- `hecks LanguageRun.project_bootstrap_table! --confirm`: Project the DSL's bootstrap-window fallbacks from the keyword rows
- `hecks LanguageRun.project_field_hints! --confirm`: Project the host's form-field hints
- `hecks LanguageRun.project_expression_tables! [--stdout] --confirm`: Project the expression machinery's operator and normalisation tables
- `hecks LanguageRun.project_reference! --confirm`: Regenerate the DSL reference from the Syntax bluebook, keeping the committed prose
- `hecks LanguageRun.propose! <word> context= [body=] [inner=] [opens=] [fills=] --confirm`: Enter a keyword row, proposed: it reaches no projection until admitted
- `hecks LanguageRun.admit! <word> context= --confirm`: Move a proposed keyword row to admitted
- `hecks LanguageRun.deprecate! <word> context= --confirm`: Move an admitted keyword row to deprecated
- `hecks LanguageRun.retire! <word> context= --confirm`: Move a deprecated or admitted keyword row to retired
- `hecks LanguageRun.rename! <word> context= new_name= --confirm`: Respell a keyword row; the old spelling keeps parsing
- `hecks LanguageRun.propose_argument! <word> context= kind= [required=] [at=] [named=] [fills=] [pairs_shape=] --confirm`: Enter an argument row of a keyword, proposed
- `hecks LanguageRun.admit_argument! <word> context= [at=] [named=] --confirm`: Move a proposed argument row to admitted
- `hecks LanguageRun.deprecate_argument! <word> context= [at=] [named=] --confirm`: Move an admitted argument row to deprecated
- `hecks LanguageRun.retire_argument! <word> context= [at=] [named=] --confirm`: Move a deprecated or admitted argument row to retired
- `hecks LanguageRun.word_status`: Where every word of the language stands: the ones not simply admitted, and the renamed.

### SyntaxBootCache

The grammar bluebooks' on-disk boot cache, keyed by a digest of the bluebooks it was built from.

- `hecks SyntaxBootCache.stale`: Every cache whose grammar changed under it and is not yet rebuilt.

### CodemodRun

One rewrite of the example bluebooks by a codemod, or the rehearsal of it.

- `hecks CodemodRun.hoist_local_givens! --confirm`: Hoist a given that several commands of one owner repeat into one owner-level given
- `hecks CodemodRun.drop_implicit_append_fields! --confirm`: Drop an attribute line that only repeats what an append target element declares
- `hecks CodemodRun.move_former_name! --confirm`: Move an aggregate's formerly_known_as out of the bluebook into the world's stored_as

### ScriptRun

One named one-off script the checkout runs, planned or applied; the body is a tool.

- `hecks ScriptRun.plan_script! <script>`: Show what a named one-off script would change, writing nothing
- `hecks ScriptRun.apply_script! <script> --confirm`: Carry out a named one-off script's changes, only when confirmed
<!-- generated:end cli -->
