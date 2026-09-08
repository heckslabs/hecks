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
  end
end
