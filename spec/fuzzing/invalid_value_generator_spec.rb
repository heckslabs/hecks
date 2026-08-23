require "spec_helper"
require "hecksagain/fuzzing/invalid_value_generator"

# The claim this generator makes is narrow and worth holding : every value it
# returns is the WRONG SHAPE for the attribute it was asked about. A generator
# that quietly produced a valid value would look like it was widening coverage
# while changing nothing, which is the failure mode a fuzzer cannot report on
# itself — a sequence full of accidentally-valid payloads still AGREES.
RSpec.describe Hecksagain::Fuzzing::InvalidValueGenerator do
  # Booted ONCE per file — every example below only reads the loaded
  # aggregate's IR back out (`described_class.corrupt`/`.kinds_for` never
  # dispatch), so a shared boot is safe.
  before(:context) do
    registry = Hecksagain::Runtime::Registry.new
    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
    end
    @aggregate = registry.bluebook("Banking").aggregate("Account")
  end

  let(:aggregate) { @aggregate }

  def attribute(command_name, argument)
    aggregate.command(command_name).attributes.find { |held| held.name.to_s == argument }
  end

  describe "determinism" do
    it "produces the same corruption for the same seed" do
      held = attribute("Credit", "amount")
      first  = described_class.corrupt(held, aggregate, random: Random.new(42))
      second = described_class.corrupt(held, aggregate, random: Random.new(42))

      expect(first).to eq(second)
    end
  end

  describe ".kinds_for" do
    it "offers a value object only the confusions a value object can suffer" do
      held = attribute("Credit", "narrative")

      expect(described_class.kinds_for(held, aggregate)).to include(:scalar_for_object)
      expect(described_class.kinds_for(held, aggregate)).not_to include(:numeral_string)
    end

    it "names every kind it offers" do
      offered = aggregate.commands.flat_map { |command|
        command.attributes.reject(&:list?).flat_map { |held| described_class.kinds_for(held, aggregate) }
      }.uniq

      expect(offered - described_class::KINDS).to be_empty
    end
  end

  describe "the corruption is real" do
    it "never hands back a plain Integer where an Integer is declared" do
      held   = attribute("Credit", "amount")
      random = Random.new(5)
      values = Array.new(60) { described_class.corrupt(held, aggregate, random: random) }

      expect(values.none? { |value| value.is_a?(Integer) }).to be(true)
    end

    # Built directly rather than drawn from banking, because banking types its
    # money as a value object — so `kinds_for` correctly never offers these two
    # for it. The kinds still have to produce what they claim to produce.
    it "builds the hash-where-a-scalar-belongs shape that once split refusal behavior" do
      held  = attribute("Credit", "amount")
      value = described_class.build(:object_for_scalar, held, aggregate, random: Random.new(5))

      expect(value).to be_a(Hash)
    end

    it "builds a numeral wearing quotes, which reads as a number and is not one" do
      held  = attribute("Credit", "amount")
      value = described_class.build(:numeral_string, held, aggregate, random: Random.new(5))

      expect(value).to be_a(String)
      expect(value).to match(/\A\d+\z/)
    end
  end

  describe ".undeclared_argument" do
    it "names an argument no command in the corpus declares" do
      declared = aggregate.commands.flat_map { |command| command.attributes.map { |held| held.name.to_s } }
      name, = described_class.undeclared_argument(random: Random.new(1))

      expect(declared).not_to include(name)
    end
  end
end
