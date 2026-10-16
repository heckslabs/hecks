# A quoted member cell stays a string

**Status:** Proposed. Built: `Assembly::Scalars.mark` and `unmark`, the `member_pair_rows` reader, the Rust parser's `cell_value`, and `spec/dispatch_load_spec.rb`. Date: 2026-10-16.

## Context

Every chapter a registry holds is what the meta-domain assembles from the chapter's own declarations, not the builder's graph
(`MetaValidator.call`). A `member` cell reached the meta-domain as text, and reading it back turned `"true"`, `"false"` and
digit-only text into a boolean or a number. A quoted `"true"` and a bare `true` came out the same, so a registry's chapter
differed from the builder's IR wherever the source quoted such a cell. The language's own `member` rows quote theirs (`at: "1"`,
`required: "true"`, `sorted: "true"`), because their attributes are `String`. The builder kept them as strings, and the consumers
of those tables (`generic_dispatch`, the parser table, the Rust vocabulary projection) compare strings. The product disagreed, and
the frozen IR in `spec/golden/ir` held its guesses. The Rust parser had ported the same guess (`unmark_scalar` in
`parse/value_object.rs`), so byte-parity between `hecks-parse` and the Ruby exporter depended on both guessing alike.

## Decision

1. **A quoted cell is a String and a bare cell is typed.** A boolean or number spells as itself. A String that would read back as
   a boolean, a number or quoted text is quoted with `Literal.quote`; every other String keeps its own spelling, so a stored word
   is unchanged. Reading a cell undoes exactly that, and a quoted cell comes back a String whatever it spells.
2. **The product equals the builder.** `Reconstruction` reads cells with `Scalars.unmark`, and `Assembly::Marks.member` takes them as
   typed. `spec/dispatch_load_spec.rb` holds a chapter loaded by dispatch to the IR its builder made, the language's chapters
   included, with no allowed difference.
3. **A consumer that needs a boolean decodes the spelling at its own boundary.** The `Comparison` vocabulary keeps its cells as
   the text `"true"` and `"false"` under `String` attributes, and the expression-tables projection reads them with
   `spelled_true?` into the booleans `projection.json` holds. They are not declared `Boolean`, because the Rust closed-set
   table codec supports `String`, `Integer`, `Float` and the `TrueClass` names, so a `Boolean` attribute in a closed set
   stops `hecks-codegen`. Nothing else in the language's tables reads a cell as typed.
4. **The Rust parser reads a cell the same way.** `cell_value` keeps a quoted cell a `Str` and a bare boolean or number typed,
   for `member` rows and for an inline `one_of:` list, so `hecks-parse` and the Ruby exporter stay byte-identical.
5. **This is the bluebook side.** It is the language's own chapter and its meta-domain; no hecksagon changes.

## Consequences

- The frozen IR of the Bluebook, World, Hecksagon and Expression chapters changes where a cell was quoted (`"true"`, `"1"` in place
  of `true`, `1`). Nothing else moves; the committed generated tables and `projection.json` do not change.
- A user chapter that quotes a number or boolean in a `member` row now gets that String in a registry, as its builder does and
  as `hecks-parse` now does; a chapter that wrote the cell bare keeps its boolean or number. Quote only what is text.
- The verdict cache is keyed on the IR, so the first boot after the change re-judges each chapter once.
