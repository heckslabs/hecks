# Phase 10's sixth shipped capability — `sets :field, multiply: :arg`, ported for real (Integer fields)

**Status:** Shipped, both generators, verified against a purpose-built fixture (no real corpus command declares `multiply` — see `docs/decisions/0041`'s own accounting of why that ADR flagged this item as "structurally close but zero real corpus motivation," and why it stayed scoped narrow here rather than trying to close that whole gap at once).

## What shipped

A declared `sets :field, multiply: :arg` mutation now generates for real, restricted to the SAME Integer-field subset `increment`/`decrement` already cover. Ground truth: `CommandRules::Arithmetic#multiply` (`lib/hecks/runtime/command_rules/arithmetic.rb`) — its own comment: "Same raw-vs-value-object branch shape as `#arithmetic`/`#arithmetic_value_object`, reused rather than duplicated verb-for-verb (a Proc picks the actual arithmetic; everything else... is identical to the additive pair)." `MutationApplier#apply`'s own `:multiply` branch confirms the SAME shape at dispatch time.

**Both generators** (`rust/project/{commands,mutations}.rb`, `rust/codegen/src/{commands,mutations}.rs`, kept in parity per ADR 0010):
- `commands.rb`'s `unsupported_ops` allow-list and `arithmetic_targets` eligibility check both widened from `%w[increment decrement]` to include `multiply` — reusing `arithmetic_target_field`/`arithmetic_amount_expr` wholesale, the exact same "can we generate this / here's how" pairing `increment`/`decrement` already use. No new eligibility logic needed.
- `mutations.rb` gained a `when "multiply"` branch, identical to `increment`/`decrement`'s own except `*` in place of `sign` (multiply carries no sign at all — `Vocabulary::MutationOp`'s own table already declares `sign: ""` for it, unlike increment/decrement's `+1`/`-1`) — reuses the SAME `mutation_arithmetic` Exemplar template.

## Deliberately narrow scope — Integer fields only, not the full `Numeric` widening

`arithmetic_target_field`'s own `integer_field_of` helper only ever matches an `Integer`-typed VO member, never `Float` — a PRE-EXISTING scope `increment`/`decrement` already carry (confirmed: Ruby's own `#arithmetic`/`#multiply` were BOTH widened from `Integer` to `Numeric` in "migration plan task 4, i106" — miette's own per-tick organ math increments a `Float` — but Rust's codegen was never widened to match, for either op). This round did NOT attempt that widening: a real corpus `Float` VO like `DailyFee.amount` is NOT reachable through `multiply` here, the exact same gap `increment`/`decrement` already have, not a new one this round introduced. Widening `integer_field_of` to `Numeric` for all three arithmetic ops together is real, separate follow-on work.

## The fixture — a purpose-built command, a real corpus attribute

No real corpus command declares `multiply` (confirmed by grep, `docs/decisions/0041`). A purpose-built fixture was used instead: a temp copy of `examples/banking` (never committed) with one new command, `Account.ScaleDailyLimit` (`attribute :factor, Integer; sets :daily_limit, multiply: :factor`), added directly into the copy's own `deposit_accounts.bluebook` alongside the real `Account` aggregate — reusing `Account`'s own real `DailyLimit` value object (`cents: Integer, default: 0`) rather than inventing a synthetic domain from scratch, so the ONLY genuinely new thing being tested is the `multiply` mutation itself, not an unfamiliar aggregate shape.

**RED, confirmed directly** (`git stash` isolation, `bin/project_wasm` + `bin/rust_conformance` against the temp domain): `Banking::Account.ScaleDailyLimit` refused as an unknown command; `daily_limit.cents` stayed at the pre-command 100000. **GREEN, confirmed directly after**: `matches.` — and substantively, by reading the rebuilt native/wasm binary's own raw JSON output directly: `daily_limit.cents` reads `300000` (100000 × a `factor` of 3), the SAME answer Ruby's own real interpreter computes for the identical script, checked independently on both sides rather than trusting the diff tool's summary alone.

## Verification

- `cargo test --no-default-features --features banking` (rust/): 49 passed, 0 failed.
- `cargo build --no-default-features --features {roster,compliance,pizzas,banking}`: all four clean (this change touches no shared struct — `QueryDef`/`ReadModelDef`-style regen was not needed at all, since `multiply` support lives entirely in per-command emitted Rust, not a compiled table row).
- `bin/rust_conformance` against the purpose-built fixture: RED before the fix (command refused, `daily_limit` unchanged), GREEN after (`matches.`, and `daily_limit.cents == 300000` confirmed directly against the compiled binary's own output).
- `bundle exec rspec spec/rust_conformance_spec.rb spec/codegen_parity_spec.rb --tag io`: 30/30 — both generators still byte-identical on every real corpus member (this path isn't exercised by any real corpus command, so byte-identity holds trivially, but confirms nothing else broke).
- `bundle exec rspec` (full suite): 2232 examples, 0 failures.
- `bundle exec rubocop -c .rubocop.yml` / `bin/doc_coverage`: clean.
- `bundle exec rspec --tag io`: 307 examples, 0 failures, 8 pending — the same pre-existing Homebrew/rustup PATH-shadowing artifact documented in `docs/decisions/0040`, confirmed unrelated (this round touches no `rust/host` code at all).

## What's still open

`clamp` and `remove` — the other two items `docs/decisions/0041` grouped with `multiply` under "structurally close, zero real corpus motivation" — were NOT ported this round; `clamp`'s own shape (bounds `[min, max]`, no "amount" argument reference at all) is genuinely different from the arithmetic-pair shape `multiply` just reused, and `remove`'s is different again (list-element removal by value, `append`'s own counterpart) — neither is a trivial extension of what just shipped, matching this session's own "one well-scoped thing at a time" discipline. `list_of admits:/pattern:`, `group_by`/`count`/`median`, `corrects`'s real admissibility half, `cursor`/`consistency`, and cross-aggregate door-argument bridging remain exactly as scoped in `docs/decisions/0041`.
