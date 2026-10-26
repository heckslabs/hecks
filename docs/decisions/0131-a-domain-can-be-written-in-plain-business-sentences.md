# A domain can be written in plain business sentences

**Status:** Accepted. Built on branch `worktree-bizbook`, not released. Date: 2026-10-25.

## Context

A bluebook is Ruby-shaped (`Hecks.bluebook "X" do … end`, `attribute :name, Type`,
`invariant("…") { … }`). The people who know the rules of a business (what may be sold, when an
order is refused, what happens next) cannot write it, so they describe it and someone else
transcribes it. `.behaviors` files do not answer this: they test a domain that already exists, in
developer notation (`setup`, `input`, `expect` with hashes).

Gherkin shows the shape business people write: indented plain text, one sentence a line,
`Given` / `When` / `Then`. Its weakness is also known: the sentences are bound to code by
hand-written step definitions, so the readable file and the running system drift.

## Decision

1. **A `.bluebook` file may be written as sentences.** Its first line, `Domain: <name>`, picks the
   grammar. Both forms lower to the same `ir.json`, so every projection, host, generator and check
   works from the IR and cannot tell which wrote it. A file is wholly one form, and the
   `.bluebook` files of one chapter must all be the same form (the parser refuses a mix). Files of
   different chapters in one project may differ. The extension is unchanged, so no glob, `loads`
   or editor association needed to learn a new file kind. This replaces the earlier idea of a
   separate `bizbook` language and a project that uses one or the other.
2. **Bluebook side, not hecksagon.** A sentence file declares what the domain is and does. It
   names no database, clock or network. Wiring stays in `.hecksagon`, and persistence stays
   memory by default. A `.hecksagon` beside a chapter written as sentences is not read by the
   sentence parser yet (see Known gaps).
3. **There is no step-definition layer: what an author may say is a table.** Each sentence is a
   `PhraseSeed` row of the `Sentence` chapter (`lib/hecks/language/sentence/sentence.bluebook`),
   projected into `rust/parser/src/phrases.rs` by `hecks language_run.project_phrase_table` and
   guarded by `spec/phrase_table_spec.rb`. A pattern is literal words, `(a|an)` alternatives and
   `{slot:kind}` fill-ins (`words`, `word`, `text`, `int`, `list`, `rest`, `path`, `event`); a row
   names the block it is legal in and the block it opens. A sentence that matches no row is
   refused with the line and column it stopped fitting at and the nearest rows, never skipped.
   Phrases are admitted by editing rows (each carries a `status`, and `Phrase.Retire` retires
   one); the keyword `propose!`/`admit!` lifecycle is not yet extended to them.
4. **The words keep their Gherkin meaning, mapped onto the IR:**

   | Sentence | IR |
   |---|---|
   | `Domain: X` and an indented paragraph | domain, `vision` |
   | `Aggregate: X` and a paragraph | aggregate, `description` |
   | `A page is identified by its slug.` | `identified_by` |
   | `It has:` lines (`a slug: page slug`, `…, optional`) | attributes |
   | `A page slug has a value: text.` | a single-value value object |
   | `Rule "…" holds when the value is not empty` | invariant (`!value.to_s.empty?`) |
   | `Lifecycle: status, starting as draft` and `Publish moves a page from draft to published` | lifecycle, transitions |
   | `Command: X`, `Goal:`, `Who:`, `It acts on an existing page`, `When a slug is given`, `Given "…" holds when the status is draft`, `Then the slug is set`, `And PageDrafted is announced` | command, `role`, `goal`, `reference_to`, attributes, given, `sets`, `emits` |
   | `Query: X`, `Where the status is draft`, `Ordered by slug.value, ascending` | query |
   | `Policy: X`, `Whenever E is announced [by an order]`, `Then C runs [with the x]` or `Then N is asked [with the x]` | policy with `trigger` or `ask` |

   A rule or given is `Rule "<description>" holds when <condition>`, so the description (which a
   refusal reports) and the checkable condition both survive. The conditions are phrase rows too
   (`the F is not empty`, `the F is at least N`, `the F is V`) and lower to the canonical
   expression text the expression machinery already turns into an AST.
5. **One reader, in Rust; Ruby runs the rendered text.** `hecks-parse` is the only parser of the
   sentences. `hecks-parse render` prints the Ruby-form text for the same IR, and
   `Hecks::SentenceForm` writes it to the cache directory, loads it with `Kernel.load` (a
   predicate's source is recovered from the file it was written in, so it has to be a real file)
   and records the sentence file as the chapter's source. `Adapters::Folder#load_file` is the
   one place a bluebook is loaded, so boot, `model_check`, the Composer and the corpus all take
   sentence files without knowing. No Ruby parser of sentences exists, and no IR importer.
6. **A formatter writes one wording.** `hecks-parse format` prints any chapter, in either form,
   as canonical sentences. Formatting then parsing returns the same IR, formatting twice changes
   nothing, and the Ruby form of `Cms::Page` formats to exactly its hand-written sentence file.
   Comments are not in the IR and are not written; the paragraph under a header is kept as the
   `description`.
7. **Authoring is a requirement, not polish.** The authors work alone. Every refusal names its
   line and column and what was in scope (the fields, types, commands or states that would have
   worked), `hecks-parse complete` offers the sentences legal at a cursor from the same table,
   and `hecks-lsp` starts a squiggle at the refusal's column and offers those sentences as
   snippets with a tab stop per fill-in.
8. **Examples are their own file, `*.examples`, and are executable.** A `.bluebook` extension
   would have every `*.bluebook` glob load an examples file as a chapter, so examples have their
   own. `Examples for: <chapter>` opens it; `Background:` introduces people and their roles
   (`Dana is an Editor`); `Example:` steps are `Given`/`When`/`Then`/`And` in the domain's words
   (`Dana drafts a page with slug "about"`, `Sam tries to publish it`, `Then the page is
   published`, `And PagePublished is announced`, `Then it is refused because only a draft can be
   published`); a `Where:` table runs an example once per row with `<column>` substituted.
   `hecks-parse examples` compiles the file against its chapter to `.behaviors` text, and the
   behaviors runner now runs an `.examples` file directly. Every name is checked against the
   chapter (a person's role, a command and the fields it takes, a lifecycle state, an event, a
   rule's own sentence), so an example can only mean something the domain declares.
   `.behaviors` tests gained `as "<role>"` and `setup …, as: "<role>"`, binding a caller for the
   dispatch (unchecked when absent, as before), so "only an Editor may publish" is provable.
9. **A command may be run by several roles, in the language and not only in sentences.**
   `Who: Customer or Sales Rep` (and `role "Customer", "Sales Rep"` in the Ruby form) lowers to
   `role` (the first) and a new `roles` key, which the IR carries only for a command that names
   more than one, so every other command, chapter and golden emits as it did. The Ruby runtime
   lets a caller through who holds any one of them, and refuses naming them all (`role: A or B,
   and the caller stated C`); the Rust generator emits `check_roles_via(&["A", "B"], …)` for such
   a command and `check_role_via` for every other, so single-role output is unchanged. The
   grammar describes it (`Command.roles`, the `Allow` command, a variadic `role` argument), and
   the fuzz adversaries and the OIDC manifest read every role. Other readers of `role` (forms,
   docs, CLI help) show the first.
10. **An outside party is an `ask`, not an outside fact.** The domain says the question
   (`Then check credit is asked`) and the events that can answer it
   (`Whenever CreditCleared is announced by an order`); the hecksagon says who answers. `needs`
   stays the clock's (`now`, `today`).

## Consequences

- Business authors get a file they can read, edit and run without Ruby punctuation; the IR, the
  Rust kernel, the host and the conformance corpora are untouched.
- The phrase table is the new surface to keep honest. It is generated like every other table, and
  the shared parity corpus (`spec/parser_parity_spec.rb`) now compares sentence fixtures with
  Ruby's IR byte for byte. `spec/fixtures/sentence/{cms_page,orders}` hold a sentence file and an
  independently written Ruby twin each.
- A chapter written as sentences needs `hecks-parse` at run time. The gem does not ship it
  (`PrebuiltBinary` rows exist for the host only); `Hecks::SentenceForm.binary` looks at
  `HECKS_PARSE_BIN`, `rust/parser/target/{release,debug}` and the `PATH`, and names the fix when
  none is found.
- Diagnostics gained an optional column (`file:line:column: message`); `Composer::Parse` and
  `hecks-lsp` read it, and a Ruby-form refusal is unchanged.

## Known gaps

These are deliberate. Each is refused loudly rather than approximated.

- **A total is written as an expression, not a sentence.** The expression language gained
  `list.sum { |x| expression }` (Ruby `Expression`, Rust `Resolver`, `ast_json`, the kernel and
  the generator), so a rule can say `lines.sum { |l| l.quantity * l.price } <= 1000`. No phrase
  row says it in words yet.
- **Comments are not kept.** Prose under a header becomes the `description`; other comments are
  dropped by a format, as the IR holds none.
- **Examples cannot stub an outside answer.** A domain that asks the outside needs a port, so its
  examples boot a Memory-bound `<name>_behaviors.hecksagon` beside them (found by
  `Hecks::SentenceForm.behaviors_hecksagon`, passed to the compiler as `--also`); nothing then
  answers the ask, and the Memory runtime refuses it, which shows in `expect emits:`. The
  commands an answer would trigger are exercised directly. A verb in an example is one word
  (`publishes`, not `requests refund`).
- **A `.hecksagon` beside a sentence chapter** is refused ("not yet implemented"). The sentence form
  covers every construct the corpus uses except: aggregate `ports`; the facts a command or query
  asks the runtime for (`needs`); a query's `cursor`; a report that pages each of several included
  aggregates separately; a policy that triggers a command no chapter in the file declares; and a
  transition naming an undeclared command. The formatter names each one it cannot write, and
  `spec/sentence_coverage_spec.rb` lists them.
- **Generated Ruby text carries no line map.** A Ruby error inside rendered text names the
  generated file; the parser has already checked the sentences, so this should be rare.

## Coverage

`spec/sentence_coverage_spec.rb` writes every bluebook in the corpus as sentences and reads the
sentences back: the IR must equal the Ruby form's exactly, or the formatter must refuse by naming
what it has no phrase for, never drop it. The refusals still allowed are listed in the spec; an
entry nothing meets any more fails it, so the list only shrinks.

## Verification

`cargo test` in `rust/parser` and `rust/lsp`; `spec/sentence_form_spec.rb`,
`spec/sentence_examples_spec.rb`, `spec/phrase_table_spec.rb` and the shared
`spec/parser_parity_spec.rb` (tagged `:io`, they build the parser).
