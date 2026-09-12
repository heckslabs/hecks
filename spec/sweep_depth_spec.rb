require "spec_helper"
require "hecks/fuzzing"

# `Hecks::Fuzzing::SweepDepth`, PROVEN AS THE PURE FUNCTION IT IS — the
# same discipline `spec/rotation_priority_spec.rb` keeps for its sibling:
# a plain table passed in, no ledger boot, no dial resolved by load order.
# The REAL dial's own boundaries (4/5, 19/20) are pinned against a booted
# `QualityControlDials` in `spec/quality_control_spec.rb`.
RSpec.describe Hecks::Fuzzing::SweepDepth do
  let(:tiers) do
    [
      { upto: 4,               seeds: 10, steps: 25 },
      { upto: 19,              seeds: 25, steps: 50 },
      { upto: Float::INFINITY, seeds: 50, steps: 100 }
    ]
  end

  it "gives the narrowest tier to a fresh target and to one just surprised" do
    expect(described_class.for_streak(0, tiers: tiers)).to eq([10, 25])
  end

  # THE TWO BOUNDARIES — each `upto` is inclusive, so 4 is still the first
  # tier and 5 is the first streak that earns the second.
  it "widens the sweep after the fifth clean release in a row" do
    expect(described_class.for_streak(4, tiers: tiers)).to eq([10, 25])
    expect(described_class.for_streak(5, tiers: tiers)).to eq([25, 50])
  end

  it "reaches the ceiling at twenty clean releases" do
    expect(described_class.for_streak(19, tiers: tiers)).to eq([25, 50])
    expect(described_class.for_streak(20, tiers: tiers)).to eq([50, 100])
  end

  it "never widens past the ceiling, however long the streak" do
    expect(described_class.for_streak(5_000, tiers: tiers)).to eq([50, 100])
  end

  it "ships a default table identical to the dial's own three rows" do
    expect(described_class.for_streak(0)).to eq([10, 25])
    expect(described_class.for_streak(20)).to eq([50, 100])
  end

  it "refuses a negative streak" do
    expect { described_class.for_streak(-1, tiers: tiers) }.to raise_error(ArgumentError, /negative/)
  end

  it "refuses a table with no ceiling row rather than guessing" do
    expect { described_class.for_streak(9, tiers: [{ upto: 4, seeds: 1, steps: 1 }]) }
      .to raise_error(ArgumentError, /Float::INFINITY/)
  end
end
