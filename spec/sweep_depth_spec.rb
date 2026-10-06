require "spec_helper"
require "hecks/fuzzing"

# `Hecks::Fuzzing::SweepDepth`, proven as the pure function it is — the
# same discipline `spec/rotation_priority_spec.rb` keeps for its sibling:
# a plain table passed in, no ledger boot, no dial resolved by load order.
# The real dial's own boundaries (4/5, 19/20) are pinned against a booted
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

  # **The two boundaries** — each `upto` is inclusive, so 4 is still the first
  # tier and 5 is the first streak that earns the second.
  it "widens the sweep after the fifth clean release in a row", :aggregate_failures do
    expect(described_class.for_streak(4, tiers: tiers)).to eq([10, 25])
    expect(described_class.for_streak(5, tiers: tiers)).to eq([25, 50])
  end

  it "reaches the ceiling at twenty clean releases", :aggregate_failures do
    expect(described_class.for_streak(19, tiers: tiers)).to eq([25, 50])
    expect(described_class.for_streak(20, tiers: tiers)).to eq([50, 100])
  end

  it "never widens past the ceiling, however long the streak" do
    expect(described_class.for_streak(5_000, tiers: tiers)).to eq([50, 100])
  end

  it "ships a default table identical to the dial's own three rows", :aggregate_failures do
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

  # `seed_offset` is what keeps a target past the ceiling tier from re-sweeping the identical seed
  # integers, and therefore the identical generated sequences, forever.
  describe ".seed_offset" do
    it "leaves a fresh or just-reset target sweeping the familiar 1..seeds range" do
      expect(described_class.seed_offset(0, 50)).to eq(0)
    end

    it "grows with the streak, one full seed-count stride per clean release", :aggregate_failures do
      expect(described_class.seed_offset(20, 50)).to eq(1000)
      expect(described_class.seed_offset(21, 50)).to eq(1050)
    end

    # Whether the seed range of the streak after `streak` starts past where its range ends.
    def ranges_clear?(streak, seeds)
      described_class.seed_offset(streak + 1, seeds) + 1 > described_class.seed_offset(streak, seeds) + seeds
    end

    it "never lets consecutive streaks' ranges overlap, at a fixed seed count" do
      overlapping = (0..30).reject { |streak| ranges_clear?(streak, 50) }

      expect(overlapping).to be_empty, "the range after each of these streaks overlaps its own: #{overlapping}"
    end

    it "restarts at 0 after a streak reset, however far the streak had climbed", :aggregate_failures do
      expect(described_class.seed_offset(5_000, 50)).to be > 0
      expect(described_class.seed_offset(0, 50)).to eq(0)
    end

    it "refuses a negative streak" do
      expect { described_class.seed_offset(-1, 50) }.to raise_error(ArgumentError, /negative/)
    end
  end
end
