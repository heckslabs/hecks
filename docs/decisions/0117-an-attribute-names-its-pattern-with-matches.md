# An attribute names its pattern with `matches:`

**Status:** Proposed. Built on this branch, not released. Date: 2026-10-17.

## Context

A String field that must look a certain way was declared with `pattern:` and a hand-written regex, and the corpus repeated the same few regexes about 250 times: `[^ \t\n\r]` (not blank) about 130 times, `[^\t\n\r]` (not empty) about 60, and identifier, hash and digit patterns a handful of times each. A regex says nothing about intent, and each copy had to be written exactly right.

Refusing blank by default was surveyed and rejected: 527 more required value-object String fields have no pattern and accept a blank today, so a default would tighten all of them at once.

## Decision

1. **`attribute` takes `matches: :name`.** The language gives a closed set of names, each standing for exactly one regex source: `present` (`[^ \t\n\r]`, a value that is not blank), `not_empty` (`[^\t\n\r]`), `no_whitespace` (`^[^ \t\n\r]+$`), `snake_name` (`^[a-z][a-z0-9_]*$`), `git_sha` (`^[0-9a-fA-F]{7,40}$`) and `digits` (`^[0-9]+$`). Each is the exact source the corpus already spelled, so no field changes meaning. The set grew as the corpus repeated more shapes: `identifier`, `csv_list`, `command_ref` (`Context::Aggregate.Command`), `host_port`, `instance_id`, `hostname`, `word_chars`, `version`, `http_scheme`, `capitalized` and `single_line`. `Hecks::Bluebook::NamedPattern::TABLE` is the full list.

2. **The name never reaches the IR.** The Ruby DSL and the Rust parser each expand the name to its regex at declaration, so the IR, the generated Rust and the runtime check see the pattern as before. `rust/parser/src/build/named_pattern.rs` and `Hecks::Bluebook::NamedPattern` hold the same table, and `spec/named_pattern_spec.rb` holds them to each other.

3. **A name the language does not give is refused**, listing the names it does. `matches:` and `pattern:` on one attribute are refused, since both state the pattern.

4. **`pattern:` stays** for anything the names do not cover: the one-off and anchored forms, emails and URLs, and the enumerations written as regexes. A pattern joins the set when the corpus repeats it. `\A...\z` and `^...$` spellings of `snake_name` now share the one canonical form.

5. **The refusal wording is unchanged.** A blank value still fails as `X.f must match [^ \t\n\r], got ""`. Rewording it changes the shared refusal table in both runtimes and is left for a later decision.

## Alternatives considered

- **Names declared per bluebook** (`pattern :slug, '...'`, then referenced). More flexible, but it needs cross-chapter resolution in the IR and in Rust.
- **Names for every pattern, one-offs included.** A name for a regex used once says no more than the regex.
- **Enumerations as `one_of:`.** About 17 patterns are closed sets written as regexes, but `one_of:` on a String mints a value object, which changes the type. Not done here.

## Consequences

- The corpus, the guides and both generators say `matches: :present` and the other names. The only IR change is the `source_text` of the checked-in pizzas corpus, and the frozen goldens of the language itself.
- Bluebooks that spell the pattern keep working.
