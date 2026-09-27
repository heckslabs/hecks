require "spec_helper"

# Non-finite floats and out-of-range integers must be refused at the coercion boundary
# (`Value::Coercion#check_numeric_fields`), not left to crash later.
RSpec.describe "numeric boundary values" do
  let(:runtime)      { Hecks.boot(File.join(InMemoryDomain::ROOT, "examples/banking")) }
  let(:atm_card)     { runtime.registry.bluebook("Banking").aggregate("ATMCard") }
  let(:daily_fee)    { atm_card.value_object("DailyFee") }

  describe "check_numeric_fields, against a Float field" do
    it "still refuses a String the same as before this fix" do
      expect { Hecks::Runtime::Value.build(daily_fee, amount: "a lot") }
        .to raise_error(Hecks::Runtime::TypeMismatch, /expects/)
    end

    it "passes an ordinary finite Float through unchanged" do
      value = Hecks::Runtime::Value.build(daily_fee, amount: 2.5)
      expect(value[:amount]).to eq(2.5)
    end

    # `is_a?(Float)` alone accepts NaN and Infinity, which would later crash `clamp` and
    # `JSON.generate` with raw Ruby errors instead of a domain refusal.
    it "refuses NaN as a TypeMismatch, not a downstream ArgumentError/JSON crash" do
      expect { Hecks::Runtime::Value.build(daily_fee, amount: Float::NAN) }
        .to raise_error(Hecks::Runtime::TypeMismatch, /finite/)
    end

    it "refuses positive Infinity as a TypeMismatch" do
      expect { Hecks::Runtime::Value.build(daily_fee, amount: Float::INFINITY) }
        .to raise_error(Hecks::Runtime::TypeMismatch, /finite/)
    end

    it "refuses negative Infinity as a TypeMismatch" do
      expect { Hecks::Runtime::Value.build(daily_fee, amount: -Float::INFINITY) }
        .to raise_error(Hecks::Runtime::TypeMismatch, /finite/)
    end

    # -0.0 is finite and round-trips through JSON, so it is deliberately not refused.
    it "still accepts -0.0 — finite, not a corruption risk, unlike NaN/Infinity" do
      value = Hecks::Runtime::Value.build(daily_fee, amount: -0.0)
      expect(value[:amount]).to eq(0.0)
    end
  end

  describe "arithmetic mutations, against the raw values PRD 05 widened the generator to produce" do
    include Hecks::Runtime::CommandRules::Arithmetic

    it "clamp on a genuinely huge Integer (Bignum) still works — Ruby has no numeric ceiling here" do
      bignum = 2**100
      expect(clamp(bignum, [0, 10], "fee")).to eq(10)
    end

    # C3.3 (docs/semantics/bluebook-semantics.md): Integer is signed 64-bit everywhere; a product
    # outside that range is an evaluation fault, not a Bignum.
    it "multiply that leaves 64 bits is a fault — Ruby's Bignum is not the language's Integer" do
      expect { multiply(2**62, 4, "fee") }
        .to raise_error(Hecks::Bluebook::Expression::EvaluationError,
                        "multiply overflowed: #{2**62} * 4 does not fit in a 64-bit integer")
    end

    it "multiply that stays within 64 bits still works" do
      expect(multiply(2**61, 2, "fee")).to eq(2**62)
    end
  end
end
