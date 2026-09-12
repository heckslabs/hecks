require "spec_helper"
require "hecks/fuzzing/value_generator"

RSpec.describe Hecks::Fuzzing::ValueGenerator do
  describe "determinism" do
    it "produces the exact same value for the same seed" do
      first  = described_class.string_value(Random.new(42))
      second = described_class.string_value(Random.new(42))

      expect(first).to eq(second)
    end

    it "produces the same sequence of primitives across types for the same seed" do
      sequence = lambda do |seed|
        random = Random.new(seed)
        [
          described_class.string_value(random),
          described_class.integer_value(random),
          described_class.float_value(random)
        ]
      end

      expect(sequence.call(7)).to eq(sequence.call(7))
    end
  end

  describe ".primitive" do
    it "answers every declared primitive type" do
      random = Random.new(1)
      Hecks::Bluebook::Attribute::PRIMITIVES.each do |type_name|
        expect { described_class.primitive(type_name, random: random) }.not_to raise_error
      end
    end

    it "refuses an undeclared type rather than guessing" do
      expect { described_class.primitive("Money", random: Random.new(1)) }.to raise_error(ArgumentError)
    end
  end

  describe ".scalar_of" do
    it "unwraps the single-field value object a declared identity is written as" do
      expect(described_class.scalar_of({ "value" => "c1" })).to eq("c1")
    end

    it "passes a bare scalar through" do
      expect(described_class.scalar_of("pizza-1")).to eq("pizza-1")
    end
  end

  describe "edge-case bias" do
    it "produces the empty string often enough to be reachable, not just theoretically possible" do
      random = Random.new(3)
      values = Array.new(200) { described_class.string_value(random) }

      expect(values).to include("")
    end

    it "produces zero and negative integers" do
      random = Random.new(3)
      values = Array.new(200) { described_class.integer_value(random) }

      expect(values).to include(0)
      expect(values.any?(&:negative?)).to be(true)
    end

    it "still produces a Bignum past f64's exact-integer ceiling for a field not shaped like a clock or count" do
      random = Random.new(3)
      values = Array.new(200) { described_class.integer_value(random, name: "TransferAmountCents value") }

      expect(values.any? { |v| v.abs >= (1 << 53) }).to be(true)
    end
  end

  # BUG#35 (QualityControl QA ledger, `lease-clock-json-precision`) — a
  # clock/count-shaped Integer field is capped away from the Bignum edge
  # case so it stops firing the already-catalogued `Json::Num`/f64
  # precision-loss class on a new site every time a new such field is
  # authored (see this module's own `CLOCK_OR_COUNT_NAME_PATTERN` and
  # `SAFE_INTEGER_EDGE_CASES` comments for the full reasoning).
  describe "clock/count value-range cap" do
    it "never produces a value past f64's exact-integer ceiling (2**53) for a clock-shaped name" do
      random = Random.new(11)
      values = Array.new(500) { described_class.integer_value(random, name: "LeaseInstant value") }

      expect(values.all? { |v| v.abs < (1 << 53) }).to be(true)
      # Still reaches the ordinary edge cases the narrower pool keeps —
      # capping is not the same as starving edge-case coverage entirely.
      expect(values).to include(0, -1)
    end

    it "never produces a value past f64's exact-integer ceiling (2**53) for a count-shaped name" do
      random = Random.new(13)
      values = Array.new(500) { described_class.integer_value(random, name: "RetryCount value") }

      expect(values.all? { |v| v.abs < (1 << 53) }).to be(true)
    end

    it "is case-insensitive and matches on either the value object's own name or the bare attribute name" do
      expect(described_class.clock_or_count_shaped?("LeaseInstant value")).to be(true)
      expect(described_class.clock_or_count_shaped?("now")).to be(true)
      expect(described_class.clock_or_count_shaped?("expires_at")).to be(true)
      expect(described_class.clock_or_count_shaped?("TTL")).to be(true)
      expect(described_class.clock_or_count_shaped?(nil)).to be(false)
      expect(described_class.clock_or_count_shaped?("TransferAmountCents value")).to be(false)
      expect(described_class.clock_or_count_shaped?("EntrySequence value")).to be(false)
    end
  end
end
