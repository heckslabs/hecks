require "json"
require "open3"
require "hecks/fuzzing"
require_relative "support/rust_conformance_helpers"

# Rust refuses an out-of-range Integer and an overflowing addition; Ruby faults the same way.
# `io: true`: builds the Rust binary and runs it as a subprocess, like rust_conformance_spec.
RSpec.describe "Rust numeric coercion — overflow/out-of-range refuses cleanly instead of corrupting", :io do
  # Distinct from rust_conformance_spec.rb's `RUST_DIR` to avoid an "already initialized
  # constant" warning when both files load in one process.
  NUMERIC_COERCION_RUST_DIR = File.join(InMemoryDomain::ROOT, "rust")
  NUMERIC_COERCION_BANKING_DOMAIN = "examples/banking".freeze

  include RustConformanceHelpers

  # Shares the process-wide memoized build so the two examples pay for one `cargo build`.
  def build_rust_for_numeric_coercion(domain_feature)
    build_rust_for(domain_feature, NUMERIC_COERCION_RUST_DIR)
  end

  # `Amend`'s `given` computes `amount.cents + adjustment.cents` (the `Expr::Add` node). The
  # adjustment is 2^63 - 2^10: exactly representable as an f64, so it survives the
  # `Json::Num(f64)` wire unrounded, yet adding the credited 10_000 overflows i64.
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

  it "L22: Ruby faults the same overflowing addition (C3.3 — Integer is 64-bit in the language, not just in Rust)" do
    result = Hecks::Fuzzing::Replay.call(NUMERIC_COERCION_BANKING_DOMAIN, overflow_steps)

    expect(result[:refusals].size).to eq(1), "expected exactly one refusal, got #{result[:refusals].inspect}"
    refusal = result[:refusals].first
    expect(refusal[:verb]).to eq("Banking::Account.LedgerEntry.Amend")
    expect(refusal[:kind]).to eq("Fault")
    expect(refusal[:error]).to include("overflowed")
    expect(result[:events].map { |e| e[:name] }).not_to include("LedgerEntryAmended")
  end

  it "L22: Rust now refuses the same overflowing addition cleanly instead of panicking or wrapping to a wrong number" do
    binary = build_rust_for_numeric_coercion("banking")
    skip "rust/Cargo.toml has no banking feature — run bin/project_rust for it first" unless binary

    stdout, status = Open3.capture2(binary, stdin_data: JSON.generate({ "steps" => overflow_steps }))
    expect(status).to be_success, "#{binary} exited #{status.exitstatus} (a panic, not a refusal):\n#{stdout}"

    output = JSON.parse(stdout)
    refusals = output.fetch("refusals")

    expect(refusals.size).to eq(1)
    expect(refusals.first["verb"]).to eq("Banking::Account.LedgerEntry.Amend")
    expect(refusals.first["error"]).to match(/overflow/i)

    # No event for the refused step, and no saturated/wrapped number in any instance.
    expect(output.fetch("events").map { |e| e["name"] }).not_to include("LedgerEntryAmended")
    serialized = JSON.generate(output.fetch("instances"))
    expect(serialized).not_to include(9_223_372_036_854_775_807.to_s) # i64::MAX
    expect(serialized).not_to include(-9_223_372_036_854_775_808.to_s) # i64::MIN
  end

  # `daily_limit.cents` is a plain Integer field; an out-of-range JSON number must refuse,
  # not saturate to i64::MAX through an unguarded `as i64` cast.
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

  it "L21: Ruby refuses the out-of-range daily_limit at the boundary too (C3.3 `integer_range`)" do
    result = Hecks::Fuzzing::Replay.call(NUMERIC_COERCION_BANKING_DOMAIN, out_of_range_steps)

    expect(result[:refusals].size).to eq(1), "expected exactly one refusal, got #{result[:refusals].inspect}"
    refusal = result[:refusals].first
    expect(refusal[:verb]).to eq("Banking::Account.Open")
    expect(refusal[:kind]).to end_with("TypeMismatch")
    expect(refusal[:error]).to eq("DailyLimit.cents must fit in a 64-bit integer, got #{HUGE_OUT_OF_RANGE}")
  end

  it "L21: Rust now refuses the out-of-range daily_limit cleanly instead of silently saturating to i64::MAX" do
    binary = build_rust_for_numeric_coercion("banking")
    skip "rust/Cargo.toml has no banking feature — run bin/project_rust for it first" unless binary

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
