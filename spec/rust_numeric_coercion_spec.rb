require "json"
require "open3"
require "hecks/fuzzing"

# L21/L22 (docs/audits/2026-08-11-bug-triage.md, Tier 7) — two silent
# numeric-corruption bugs in the Rust kernel, re-verified against current
# code and fixed:
#
#   L21 — `rust/src/kernel/json.rs`'s `f64 -> i64` casts (`as_i64`,
#   `Fielded::field`/`items`, `to_id_component`) used Rust's own `as i64`
#   cast unguarded. That cast does not panic or truncate on an
#   out-of-range float — it SATURATES to `i64::MAX`/`i64::MIN` silently.
#   Every generated `from_json` in `rust/src/generated/**` already calls
#   `.as_i64().ok_or_else(|| Refusal::TypeMismatch(...))`, so the actual
#   fix was narrow: make `as_i64` (via the new private `integral_i64`
#   helper) return `None` for an integral-looking float outside `i64`'s
#   own range, same as it already did for a genuinely fractional one —
#   every one of those existing call sites then refuses cleanly for free.
#
#   L22 — `rust/src/kernel/expression_operators/arithmetic.rs`'s `sum`
#   (the `Expr::Add` node's evaluator — `expr.rs:239`'s line number in the
#   audit has drifted; the code moved into its own file, unchanged in
#   substance) used plain `l + r` on two `i64`s: an uncontrolled panic in
#   a debug build, a silently wrapped wrong number in a release build.
#   Fixed to `checked_add`, refusing cleanly on overflow.
#
# Ruby's `Integer` promotes to Bignum with no ceiling; this Rust kernel
# has no arbitrary-precision integer type anywhere (confirmed by grep —
# no `i128`, no `BigInt`, `Json::Num` is a plain `f64` end to end) and
# adding one is out of scope for this fix. True byte-for-byte parity with
# Ruby's Bignum semantics is therefore NOT achievable here — this spec
# proves the realistic, honest alternative instead: Ruby's own reference
# engine executes both scenarios below without complaint (real Bignum,
# no ceiling), while the compiled Rust binary now REFUSES cleanly with a
# `TypeMismatch`-shaped message — never a crash, and never a silently
# wrong (saturated/wrapped) number standing in for the real one.
#
# `io: true` — a real `cargo build` plus a subprocess run, same
# convention `spec/rust_conformance_spec.rb` already uses for exactly
# this reason (excluded locally by default, always run in CI).
RSpec.describe "Rust numeric coercion — overflow/out-of-range refuses cleanly instead of corrupting", :io do
  # Distinct names from `spec/rust_conformance_spec.rb`'s own `RUST_DIR` —
  # both files' `describe` blocks assign at the same enclosing constant
  # scope, so reusing that name triggers a "already initialized constant"
  # warning across the two files when both load in one process.
  NUMERIC_COERCION_RUST_DIR = File.join(InMemoryDomain::ROOT, "rust")
  NUMERIC_COERCION_BANKING_DOMAIN = "examples/banking".freeze

  # Same helper `spec/rust_conformance_spec.rb` defines for itself — built
  # fresh for banking every time, never trusting an ambient binary left
  # over from some other domain's own build (that exact failure mode is
  # cited in that file's own comment).
  def build_rust_for(domain_feature)
    cargo_toml = File.read(File.join(NUMERIC_COERCION_RUST_DIR, "Cargo.toml"))
    unless cargo_toml =~ /^#{Regexp.escape(domain_feature)}\s*=\s*\[\]/
      # `--features banking` alone (no `--no-default-features`) also
      # builds correctly today — see the fix report — so fall back to
      # that rather than skipping outright if the bracketed-empty-array
      # declaration this regex expects ever changes shape.
      return system("cargo", "build", "--features", domain_feature, chdir: NUMERIC_COERCION_RUST_DIR,
                    out: File::NULL, err: File::NULL) &&
             pick_binary
    end

    built = system("cargo", "build", "--no-default-features", "--features", domain_feature,
                   chdir: NUMERIC_COERCION_RUST_DIR, out: File::NULL, err: File::NULL)
    built ? pick_binary : nil
  end

  def pick_binary
    binary = File.join(NUMERIC_COERCION_RUST_DIR, "target", "debug", "rust")
    File.executable?(binary) ? binary : nil
  end

  # L22 — `LedgerEntry.Amend`'s own declared `given` (examples/banking/
  # bluebook/deposit_accounts.bluebook: "an amendment leaves a
  # non-negative amount") computes `amount.cents + adjustment.cents`,
  # exactly the `Expr::Add` node `arithmetic.rs::sum` evaluates. The
  # existing ledger entry (posted by the `Credit` step below) holds
  # `amount.cents == 10_000`; `adjustment.cents` here is `2^63 - 2^10`
  # (`9223372036854774784`) — chosen specifically because it's exactly
  # representable as an `f64` (a run of 53 one-bits, right at `f64`'s own
  # mantissa precision) so it survives this kernel's `Json::Num(f64)`
  # wire format with no rounding of its own to confound the comparison,
  # while still being large enough that adding `10_000` overflows `i64`.
  HUGE_BUT_EXACT_I64 = 9_223_372_036_854_774_784
  OVERFLOWING_ADJUSTMENT = HUGE_BUT_EXACT_I64

  def overflow_steps
    [
      { "verb" => "Banking::Customer.Register",
        "args" => { "reference" => { "value" => "CUST-OVERFLOW" }, "name" => { "given" => "Ada", "family" => "Lovelace" },
"email" => { "address" => "ada@example.com" } } },
      { "verb" => "Banking::Account.Open",
        "args" => { "number" => { "value" => "acct-overflow" }, "kind" => { "name" => "current" },
"daily_limit" => { "cents" => 50_000 }, "customer" => "CUST-OVERFLOW" } },
      { "verb" => "Banking::Account.Credit",
        "args" => { "amount" => { "cents" => 10_000, "currency" => "USD" }, "narrative" => { "text" => "Opening deposit" },
"number" => { "value" => "acct-overflow" } } },
      { "verb" => "Banking::Account.LedgerEntry.Amend",
        "args" => { "sequence" => { "value" => 1 }, "adjustment" => { "cents" => OVERFLOWING_ADJUSTMENT, "currency" => "USD" },
                    "narrative" => { "text" => "A correction too large to add" }, "number" => { "value" => "acct-overflow" } } }
    ]
  end

  it "L22: Ruby's Bignum handles the addition with no refusal at all (the parity gap this fix cannot close)" do
    result = Hecks::Fuzzing::Replay.call(NUMERIC_COERCION_BANKING_DOMAIN, overflow_steps)

    expect(result[:refusals]).to be_empty, "Ruby unexpectedly refused: #{result[:refusals].inspect}"
  end

  it "L22: Rust now refuses the same overflowing addition cleanly instead of panicking or wrapping to a wrong number" do
    binary = build_rust_for("banking")
    unless binary
      skip "could not build a banking-feature Rust binary — either rust/Cargo.toml has no banking feature " \
           "(run bin/project_rust for it first), or `cargo build --features banking` itself failed " \
           "(check for unrelated concurrent codegen changes under rust/src/generated/)"
    end

    stdout, status = Open3.capture2(binary, stdin_data: JSON.generate({ "steps" => overflow_steps }))
    expect(status).to be_success, "#{binary} exited #{status.exitstatus} (a panic, not a refusal):\n#{stdout}"

    output = JSON.parse(stdout)
    refusals = output.fetch("refusals")

    expect(refusals.size).to eq(1)
    expect(refusals.first["verb"]).to eq("Banking::Account.LedgerEntry.Amend")
    expect(refusals.first["error"]).to match(/overflow/i)

    # The whole point: no event for the refused Amend step itself (the
    # earlier Register/Open/Credit steps still succeed and emit their own
    # events), and no instance state anywhere holding a saturated/wrapped
    # stand-in number.
    expect(output.fetch("events").map { |e| e["name"] }).not_to include("LedgerEntryAmended")
    serialized = JSON.generate(output.fetch("instances"))
    expect(serialized).not_to include(9_223_372_036_854_775_807.to_s) # i64::MAX
    expect(serialized).not_to include(-9_223_372_036_854_775_808.to_s) # i64::MIN
  end

  # L21 — `Account.Open`'s `daily_limit.cents` (`DailyLimit`, a plain
  # Integer-typed field) goes through the exact same generated
  # `x.as_i64().ok_or_else(...)` this fix repairs. A JSON number far
  # outside `i64`'s range used to silently become `Some(i64::MAX)` via
  # the unguarded `as i64` cast; it must now be a clean refusal instead.
  HUGE_OUT_OF_RANGE = 10**30

  def out_of_range_steps
    [
      { "verb" => "Banking::Customer.Register",
        "args" => { "reference" => { "value" => "CUST-HUGE" }, "name" => { "given" => "Grace", "family" => "Hopper" },
"email" => { "address" => "grace@example.com" } } },
      { "verb" => "Banking::Account.Open",
        "args" => { "number" => { "value" => "acct-huge-limit" }, "kind" => { "name" => "current" },
"daily_limit" => { "cents" => HUGE_OUT_OF_RANGE }, "customer" => "CUST-HUGE" } }
    ]
  end

  it "L21: Ruby's Bignum accepts the oversized daily_limit with no refusal (the parity gap this fix cannot close)" do
    result = Hecks::Fuzzing::Replay.call(NUMERIC_COERCION_BANKING_DOMAIN, out_of_range_steps)

    expect(result[:refusals]).to be_empty, "Ruby unexpectedly refused: #{result[:refusals].inspect}"
  end

  it "L21: Rust now refuses the out-of-range daily_limit cleanly instead of silently saturating to i64::MAX" do
    binary = build_rust_for("banking")
    unless binary
      skip "could not build a banking-feature Rust binary — either rust/Cargo.toml has no banking feature " \
           "(run bin/project_rust for it first), or `cargo build --features banking` itself failed " \
           "(check for unrelated concurrent codegen changes under rust/src/generated/)"
    end

    stdout, status = Open3.capture2(binary, stdin_data: JSON.generate({ "steps" => out_of_range_steps }))
    expect(status).to be_success, "#{binary} exited #{status.exitstatus} (a panic, not a refusal):\n#{stdout}"

    output = JSON.parse(stdout)
    refusals = output.fetch("refusals")

    expect(refusals.size).to eq(1)
    expect(refusals.first["verb"]).to eq("Banking::Account.Open")
    expect(refusals.first["error"]).to include("DailyLimit.cents expects Integer")

    # Never a silently-clamped i64::MAX standing in for the real value.
    expect(output.fetch("instances").to_s).not_to include(9_223_372_036_854_775_807.to_s)
  end
end
