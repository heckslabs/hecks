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
  I64_MAX = 9_223_372_036_854_775_807
  I64_MIN = -9_223_372_036_854_775_808

  OVERFLOW_STEPS = [
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
  ].freeze

  # `daily_limit.cents` is a plain Integer field; an out-of-range JSON number must refuse,
  # not saturate to i64::MAX through an unguarded `as i64` cast.
  HUGE_OUT_OF_RANGE = 10**30

  OUT_OF_RANGE_STEPS = [
    { "verb" => "Banking::Customer.Register",
      "args" => { "reference" => { "value" => "CUST-HUGE" }, "name" => { "given" => "Grace", "family" => "Hopper" },
                  "email" => { "address" => "grace@example.com" } } },
    { "verb" => "Banking::Account.Open",
      "args" => { "number" => { "value" => "acct-huge-limit" }, "kind" => { "name" => "current" },
                  "daily_limit" => { "cents" => HUGE_OUT_OF_RANGE }, "customer" => "CUST-HUGE" } }
  ].freeze

  # What the compiled Rust binary answers for `steps`; skips when the banking feature is not built.
  def rust_output_for(steps)
    binary = build_rust_for_numeric_coercion("banking")
    skip "rust/Cargo.toml has no banking feature — run hecks project_rust for it first" unless binary

    stdout, status = Open3.capture2(binary, stdin_data: JSON.generate({ "steps" => steps }))
    expect(status).to be_success, "#{binary} exited #{status.exitstatus} (a panic, not a refusal):\n#{stdout}"
    JSON.parse(stdout)
  end

  # Exactly one refusal in the Rust binary's output, of the given verb and error.
  def rust_refusal(verb, error) = match([a_hash_including("verb" => verb, "error" => error)])

  # Exactly one refusal, of the given verb, kind and error.
  def one_refusal(verb, kind, error) = match([a_hash_including(verb: verb, kind: kind, error: error)])

  it "L22: Ruby faults the same overflowing addition (C3.3 — Integer is 64-bit in the language, not just in Rust)",
     :aggregate_failures do
    result = Hecks::Fuzzing::Replay.call(NUMERIC_COERCION_BANKING_DOMAIN, OVERFLOW_STEPS)

    expect(result[:refusals]).to one_refusal("Banking::Account.LedgerEntry.Amend", "Fault", a_string_including("overflowed")),
                                 "expected exactly one refusal, got #{result[:refusals].inspect}"
    expect(result[:events].map { |e| e[:name] }).not_to include("LedgerEntryAmended")
  end

  it "L22: Rust now refuses the same overflowing addition cleanly instead of panicking or wrapping to a wrong number",
     :aggregate_failures do
    output = rust_output_for(OVERFLOW_STEPS)

    expect(output.fetch("refusals")).to rust_refusal("Banking::Account.LedgerEntry.Amend", match(/overflow/i))
    # No event for the refused step, and no saturated/wrapped number in any instance.
    expect(output.fetch("events").map { |e| e["name"] }).not_to include("LedgerEntryAmended")
    expect(JSON.generate(output.fetch("instances"))).not_to include(I64_MAX.to_s, I64_MIN.to_s)
  end

  it "L21: Ruby refuses the out-of-range daily_limit at the boundary too (C3.3 `integer_range`)", :aggregate_failures do
    result = Hecks::Fuzzing::Replay.call(NUMERIC_COERCION_BANKING_DOMAIN, OUT_OF_RANGE_STEPS)
    error = "DailyLimit.cents must fit in a 64-bit integer, got #{HUGE_OUT_OF_RANGE}"

    expect(result[:refusals]).to one_refusal("Banking::Account.Open", a_string_ending_with("TypeMismatch"), error),
                                 "expected exactly one refusal, got #{result[:refusals].inspect}"
  end

  it "L21: Rust now refuses the out-of-range daily_limit cleanly instead of silently saturating to i64::MAX",
     :aggregate_failures do
    output = rust_output_for(OUT_OF_RANGE_STEPS)

    expect(output.fetch("refusals")).to rust_refusal("Banking::Account.Open", include("DailyLimit.cents expects Integer"))
    # Never a silently-clamped i64::MAX standing in for the real value.
    expect(output.fetch("instances").to_s).not_to include(I64_MAX.to_s)
  end
end
