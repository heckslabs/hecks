require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# With the owner's `protection.signalbox` switch on, a fill's boot-share hold is Signalbox's
# breakers, tripped by dry run in the order `Breaker`'s Order rows declare: the machine fuse
# holds new coders only once the helper share, the smaller breaker, cannot act.
RSpec.describe "protection by Signalbox's breakers" do
  describe Hecks::Adapters::Dispatching::Protecting do
    def sessions(coders, helpers) = -> { ([{ role: "coder" }] * coders) + ([{ role: "helper" }] * helpers) }

    # A machine fuse rated at the 25 percent share mark; nil is a load under its high mark.
    def protecting(share:, coders:, helpers:)
      reading = share && { load: share, rating: 25 }
      described_class.new(share: -> { reading }, sessions: sessions(coders, helpers),
                          door: Hecks::Adapters::Dispatching::SignalboxDoor.new)
    end

    it "lets coders start while the helper share acts first, though the boot fuse is past its rating" do
      expect(protecting(share: 40, coders: 3, helpers: 80).stop).to be_nil
    end

    it "names the helper share as the breaker that acts first" do
      expect(protecting(share: 40, coders: 3, helpers: 80).clause).to include("helpers acts first (80 of 3 helpers)")
    end

    it "holds new coders on the machine fuse once the helpers are within their share" do
      expect(protecting(share: 40, coders: 3, helpers: 2).stop)
        .to eq("skipped: breaker machine tripped: 40 of 25 percent of CPU in boots")
    end

    it "holds nothing while every breaker is under its rating" do
      expect(protecting(share: 10, coders: 3, helpers: 2).stop).to be_nil
    end

    it "holds nothing when the load is under its high mark, whatever the boot share" do
      expect(protecting(share: nil, coders: 3, helpers: 2).stop).to be_nil
    end
  end

  describe Hecks::Adapters::Dispatching::SignalboxDoor do
    it "reads the protection order from a standalone Signalbox, the machine fuse last" do
      expect(described_class.new.order.map { |row| [row[:level], row[:holds]] })
        .to eq([%w[fuse no], %w[helpers no], %w[shedding no], %w[model yes], %w[machine yes]])
    end
  end

  describe Hecks::Adapters::Dispatching::ProtectionSwitch do
    def registry(world) = double(world: double(for_verb: world))

    it "is off when the world names no protection line" do
      expect(described_class.on?(registry(nil))).to be(false)
    end

    it "is on when the world says signalbox: true" do
      expect(described_class.on?(registry({ signalbox: true }))).to be(true)
    end
  end
end
