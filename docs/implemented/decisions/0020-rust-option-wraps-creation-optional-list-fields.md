# A list-typed record field is `Option`-wrapped only when a creating command's own `:set` can leave it unset

**Status:** Accepted — implemented. `rust/project/{types,fielded,json_codec,commands,mutations}.rb`, branch `feat/rust-projection`. Closes the last named gap: `CardPayment.tags`'s `nil`-vs-`[]` representation, the one 0014 flagged and explicitly left open pending "the real distinguishing fact Ruby carries."

## Context

Ruby represents `Banking::CardPayment#tags` as `nil` when a call omits `Authorize`'s own `tags:` argument, but `Banking::Account#ledger` as `[]` when no ledger entries have posted yet — both list-typed attributes, both legitimately empty, but rendered two different ways. 0014's own reverted heuristic (empty list → JSON `null`, universally) fixed the first and broke the second, because it guessed at the distinguishing fact instead of finding it. A dedicated investigation (this decision) traced it to Ruby's actual mechanics, not a surface pattern: `Instance.defaults` starts every list attribute at `[]` on creation; that baseline survives untouched for `ledger` (only ever the target of `Credit`/`Debit`'s own `append`, never a creating command's `:set`), but gets overwritten for `tags` because `CardPayment.Authorize` declares an explicit `then_set :tags, to: :tags` — and EVERY declared mutation runs unconditionally during `apply_mutations`, regardless of whether its source argument was actually supplied. `resolve_source`/`Value.for_attribute` pass a genuinely missing argument through as `nil`, and that `nil` overwrites the `[]` baseline.

## Decision

**Option-wrap a record's list field exactly when some creating command declares a `:set`-op mutation targeting it, sourced from an argument that command itself declares `optional: true`** — `list_attr_creation_optional?` (`mutations.rb`), the one new predicate this fix adds. Every other list field (the common case — append-only, no creation-time `:set`) keeps the existing `Vec<T>`/`vec![]` behavior untouched, which was already correct.

Four call sites needed the same predicate, mirroring exactly the places `emit_record`'s original "lists are never `Option`-wrapped" rule was baked in as an assumption:
- `types.rb`'s `emit_record` — the struct field's own declared type.
- `fielded.rb`'s `emit_fielded_record` — reading the field generically (`Fielded::field`) needs the same `Option`-aware branch every other conditionally-optional field already has.
- `json_codec.rb`'s `emit_to_json_flat` — a RECORD's own `to_json` (the `optional: true` call site) needed a NEW `aggregate:` parameter threaded in specifically for this check, because the record's own attribute-level `optional:` flag (`CardPayment`'s own `tags` attribute) is near-always `false` even when the COMMAND argument feeding it is `optional: true` — the aggregate-level and command-level `IR::Attribute`s for the same-named field are two different declarations with two different `optional:` values, confirmed against the golden IR directly.
- `commands.rb`'s creation-time `record_fields`, and `mutations.rb`'s `emit_mutation_line`'s `:set` branch (`CardPayment.Authorize`'s own mutation IS this exact `then_set`, so both the implicit creation-time assignment AND the redundant explicit re-set needed the matching Option-aware branch, or the second would have re-introduced a type mismatch the first branch just fixed).

## Consequences

- Verified on the full corpus: **35/35 matching instances — full parity**, up from 31/35. This was the last of the corpus-level mismatches this whole arc (0013 through 0020) has been closing one at a time.
- Full `bundle exec rspec` (1073 examples) and `bin/model_check` green. WASM artifact rebuilt and diffed against the Ruby oracle on both pinned CI fixtures — the same two pre-existing cosmetic gaps only (event payload formatting, refusal wording — neither reaches the `instances`/`refusals` surface the pinned spec itself compares), no new ones.
- The investigation this decision is built on also confirmed the general rule is narrower than 0014's own shorthand ("was this list attribute ever a matched creating-command argument at all") suggested: the OPERATIVE fact is the unconditional `:set` mutation resolving to `nil`, not the argument declaration by itself. A creating command using `then_set attr, append: {...}` on a list (not `:set`) would never produce `nil` — no such case exists in this corpus, but `list_attr_creation_optional?`'s own guard (`m[:op] == :set`) is precise about it rather than accidentally correct.

## Rejected alternatives

- **Re-attempting the empty-list-to-`Json::Null` heuristic**, this time gated somehow. Rejected — the actual distinguishing fact lives in the IR (a `:set` mutation sourced from an optional argument), not in whatever value a list happens to hold at serialization time; any heuristic based on the CURRENT emptiness of a list is answering the wrong question, the same mistake 0014's own attempt made.
