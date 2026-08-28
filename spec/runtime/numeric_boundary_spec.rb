require "spec_helper"

# PRD 05 (numeric-boundary-coverage) — `ValueGenerator::FLOAT_EDGE_CASES`
# had no NaN, no Infinity, no -0.0, and `INTEGER_EDGE_CASES` had no
# Bignum: "classic silent-corruption territory," per the PRD's own words,
# never exercised by a single spec repo-wide before this. Traced each
# through `Value::Coercion#check_numeric_fields` and
# `CommandRules::Arithmetic`, real corpus value object (`Banking::
# ATMCard::DailyFee`, `attribute :amount, Float`), same convention
# `identifier_numeric_coercion_growth_spec.rb` already established for
# direct coercion-boundary testing.
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

    # THE ACTUAL FINDING — before this fix, `given.is_a?(expected)` was
    # true for NaN and both Infinities (each really is a Float), so all
    # three sailed straight through with no refusal at all. Left
    # unchecked, a NaN reaching `CommandRules::Arithmetic#clamp` crashes
    # with a raw `ArgumentError` (`comparison of Float with 0 failed` —
    # confirmed directly: `Float::NAN.clamp(0, 10)` raises, it does not
    # return), and ANY non-finite Float reaching `JSON.generate`/
    # `#to_json` (storage, replay, the `bin/run` contract) crashes with
    # `JSON::GeneratorError: NaN/Infinity not allowed in JSON` — both a
    # genuine Ruby-level crash, never a domain refusal, the exact failure
    # mode this file's own header (`check_numeric_fields`'s doc comment)
    # already names for a mistyped field.
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

    # -0.0 is deliberately NOT refused — it IS finite (`(-0.0).finite?` is
    # true), round-trips through JSON cleanly (confirmed: `{a: -0.0}
    # .to_json` => `'{"a":-0.0}'`, no error), and is a legitimate signed-
    # zero value, not a corruption risk.
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

    it "multiply on a Bignum still works" do
      bignum = 2**100
      expect(multiply(bignum, 2, "fee")).to eq(bignum * 2)
    end
  end
end
