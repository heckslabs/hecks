require "spec_helper"
require "hecks/fuzzing"

# A malformation is at most one per step, so the check that fired is identifiable.
RSpec.describe Hecks::Fuzzing::SequenceGenerator::ArgumentDrawing do
  let(:drawer) do
    Class.new do
      include Hecks::Fuzzing::SequenceGenerator::ArgumentDrawing

      def initialize(random) = @random = random
      public :drop_one
    end
  end
  let(:aggregate) { Struct.new(:identified_by).new(:id) }
  let(:args) { { "id" => "i", "a" => 1, "b" => 2, "c" => 3, "d" => 4 } }

  def dropped_by(seed, needed: [])
    args.keys - drawer.new(Random.new(seed)).drop_one(args, aggregate, needed).keys
  end

  it "drops exactly one argument, whatever the seed", :aggregate_failures do
    sizes = (1..50).map { |seed| dropped_by(seed).size }

    expect(sizes.uniq).to eq([1])
  end

  it "never drops the identity or a fact the runtime answers", :aggregate_failures do
    dropped = (1..50).flat_map { |seed| dropped_by(seed, needed: ["a"]) }

    expect(dropped).not_to include("id", "a")
  end

  it "reaches every droppable argument over enough seeds" do
    expect((1..50).flat_map { |seed| dropped_by(seed) }.uniq.sort).to eq(%w[a b c d])
  end

  it "leaves the arguments alone when none is droppable" do
    only_identity = { "id" => "i" }

    expect(drawer.new(Random.new(1)).drop_one(only_identity, aggregate, [])).to eq(only_identity)
  end
end
