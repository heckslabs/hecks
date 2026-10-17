# An attribute says `present: true` instead of spelling the blank-refusing pattern

**Status:** Proposed. Built on this branch, not released. Date: 2026-10-17.

## Context

The way to refuse a blank String was `pattern: '[^ \t\n\r]'`, written by hand on every field that needed it: 130 value-object fields across the examples, the language's own bluebooks, the stress domains and the fixtures, and stamped by the interview generator and `domain_stub` on every field they write. The regex says nothing about intent, and each site had to be written exactly right.

A survey of value-object String fields found 527 more required ones with no pattern, which accept a blank today. Refusing blank by default would tighten all of them at once, and with them stored data, the Rust conformance corpus and the generated code. That is a separate and larger decision, and is not taken here.

## Decision

1. **`attribute` takes `present: true`.** It states that the value is not blank. Both parsers (the Ruby DSL and the Rust parser) read it as the pattern `[^ \t\n\r]` and nothing else: the IR, the generated Rust and the runtime check see the same pattern as before, so behavior does not change. The grammar rows are admitted in every context that admits `pattern:`.

2. **`present:` and `pattern:` on one attribute are refused.** Both state the pattern, so one of them would silently win.

3. **The refusal wording is unchanged.** A blank value is still refused as `X.f must match [^ \t\n\r], got ""`. Rewording it is a change to the shared refusal table in both runtimes and is left for a later decision.

4. **Patterns that mean more than blank stay patterns.** `^[^ \t\n\r]+$` (no whitespace anywhere) and the other anchored forms are stricter than `present: true` and are not rewritten.

## Consequences

- The corpus, the guides and both generators spell the blank rule as `present: true`. The only IR change is the `source_text` of the checked-in pizzas corpus.
- Old bluebooks that spell the pattern keep working.
- The error text still shows the regex. Showing "must not be blank" would need the refusal table changed in the Ruby and Rust runtimes together.
