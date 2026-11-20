require "spec_helper"
require "hecks/fuzzing/sequence_generator"

RSpec.describe Hecks::Fuzzing::SequenceGenerator::SeededClock do
  it "reads the same instants for the same seed" do
    expect(Array.new(3) { described_class.new(9).now }).to all(eq(described_class.new(9).now))
  end

  it "moves forward one tick a reading" do
    clock = described_class.new(9)
    expect(clock.now - clock.now).to eq(-described_class::TICK)
  end

  it "answers today as the whole days of the next reading" do
    expect(described_class.new(9).answer("today")).to eq(described_class.new(9).now / described_class::DAY)
  end
end
