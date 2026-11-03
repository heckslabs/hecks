# `clamp` mutation op — ported for real (Integer fields only)

**Status:** Shipped. ADR 0041 grouped `clamp` with `multiply`/`remove` as "structurally close [to `increment`/`decrement`], but zero real corpus motivation." `multiply` shipped first (ADR 0042, reusing `#arithmetic`'s own machinery directly). `clamp` is genuinely different — no "amount" argument at all — and needed its own eligibility check and emission, though it reuses the SAME target-field-eligibility half (`arithmetic_target_field`) `increment`/`decrement`/`multiply` already share.

## Ruby's real shape, read directly

`CommandRules::Arithmetic#clamp(current, bounds, target)` (`lib/hecks/runtime/command_rules/arithmetic.rb`) — bounds the CURRENT value into `[min, max]`. Declared as `sets :field, clamp: [min, max]` (`command_builder.rb`'s own comment: "its source is always a literal `[min, max]` pair, never an argument reference... it does not reuse `arithmetic`/`arithmetic_value_object` at all"). Dispatched from `CommandInterpreter::MutationApplier#apply`'s own `when :clamp` branch (`command_interpreter/mutation_applier.rb`): `instance[mutation.target] = @rules.clamp(instance[mutation.target], mutation.source, mutation.target)` — no `rewrap_arithmetic_result` call (unlike increment/decrement/multiply), because `#clamp`'s own Value-wrapped branch already returns a correctly-typed `Value` via `.with`.

`classified_source` (`lib/hecks/bluebook/behaviour/command.rb`) confirms the wire shape: anything that isn't a Symbol or a `StateRef` becomes `{kind: "literal", value: source}` untouched, so a `clamp:` mutation's `source` is always `{kind: "literal", value: [min, max]}` — a literal two-element Array, a shape no other mutation op's source ever takes.

## What was ported

Both generators (`rust/project/{commands,mutations,bridging}.rb`, mirrored in `rust/codegen/src/{commands,mutations,bridging}.rs`):

- **Eligibility**: `clamp` added to `unsupported_ops`'s allow-list. A new check requires `arithmetic_target_field` to resolve (the SAME Integer-VO-wrapped-field scope `increment`/`decrement`/`multiply` already share — not widened here either) AND a new `clamp_bounds_ints` to resolve (the literal source must be a two-element Array of Integers — Ruby's own Integer-only scope for this generator, matching `integer_field_of`'s existing restriction).
- **Emission**: `record.field.clamp(min, max)`, reusing the exact `mutation_arithmetic` Exemplar template increment/decrement/multiply already use, with `.clamp(min, max)` in place of an arithmetic operator and no amount expression to resolve at all. Rust's own `i64::clamp(self, min, max)` (`Ord::clamp`) matches Ruby's `Integer#clamp(min, max)` exactly: below `min` returns `min`, above `max` returns `max`, otherwise unchanged.

No new struct or type was needed — `clamp`'s bounds render as two plain Rust integer literals directly in the `.clamp(...)` call, nothing to bridge into a typed argument struct at all.

## Verification

- **RED**: purpose-built fixture (temp copy of `examples/banking`, a synthetic `Account.ClampDailyLimit` command added — `sets :daily_limit, clamp: [0, 100_000]`, reusing the real `DailyLimit { cents: Integer }` VO) generated via `bin/project_rust` before the fix: `skipping Banking::Account.ClampDailyLimit: sets op(s) clamp not generated yet (only append/set/increment/decrement/multiply/delegate are)`.
- **GREEN**: after the fix, generates `{ let current = record.daily_limit.clone().unwrap(); record.daily_limit = Some(DailyLimit { cents: current.cents.clamp(0, 100000), ..current }); }`. `cargo build --no-default-features --features clamp_fixture` compiles clean. `bin/rust_conformance <fixture> <script> native` reports **"matches."** on a script opening one account at `daily_limit.cents: 999999` (clamped down to `100000`, above-bound case) and another at `50000` (unchanged, within-bound case) — both engines agree exactly, and the final states confirm clamp did the right thing in both directions, not just that the two engines agree with each other.
- **Both generators agree on the new path too**, not just on real corpus: a direct side-by-side run of `RustProjection::DomainGenerator.call` and the `hecks-codegen` binary against the same fixture IR produced byte-identical `account.rs` output — the clamp emission itself was ported to both generators in lockstep, not just the Ruby one.
- **Real corpus unaffected**: `bin/project_rust examples/banking` regenerates with exactly one expected diff — `Account.CorrectFee`'s own "not generated yet" message text now lists `multiply/clamp` among the supported ops (a legitimate catch-up: the `multiply` commit had updated this message's wording in source but never regenerated banking's own on-disk manifest, so it was already one message-text update behind before this round; this commit closes that gap too). No other generated file changed.
- `spec/codegen_parity_spec.rb --tag io`: 8/8, both generators still byte-identical on every real corpus domain.
- Full sweep: `bundle exec rspec` (2232/0), `bundle exec rubocop` (645 files, 0 offenses), `cargo build --no-default-features --features banking` clean.
- Fixture cleanup: the purpose-built `clamp_fixture` domain and its generated Rust output were never committed; byproduct dirtying of `rust/Cargo.toml`/`rust/src/generated/mod.rs`/unrelated `governance`/`identity` files from the throwaway builds was reverted via `git checkout --` before this commit.

## What's still not ported

`remove` (list-element removal by value) remains open — a genuinely different emission shape (list-element matching, not a target-field bound or combine), not a trivial follow-on from `clamp`'s own bounds-literal shape. `corrects` and `group_by`/`count`/`median` remain open per ADR 0041, needing new kernel/adapter infrastructure this round didn't build.
