require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# With the owner's `protection.signalbox` switch on, a fill's boot-budget hold is Signalbox's
# breakers, tripped by dry run in the order `Breaker`'s Order rows declare: the boot fuse holds new
# coders only once the helper share, the smaller breaker, cannot act.
RSpec.describe "protection by Signalbox's breakers" do
  describe Hecks::Adapters::Dispatching::Protecting do
    def boots(minutes, capped: false)
      reading = Hecks::Adapters::BootBudget::Reading.new(hours: minutes / 60.0, capped: capped)
      double(today: reading)
    end

    def sessions(coders, helpers) = -> { ([{ role: "coder" }] * coders) + ([{ role: "helper" }] * helpers) }

    # A machine whose `cpu_budget` is 36 hours (2160 boot minutes), as the owner turned it.
    def protecting(minutes:, coders:, helpers:, capped: false)
      described_class.new(budget: 36.0, boots: boots(minutes, capped: capped), legacy: -> { "skipped: boot budget spent" },
                          sessions: sessions(coders, helpers), door: Hecks::Adapters::Dispatching::SignalboxDoor.new)
    end

    it "lets coders start while the helper share acts first, though the boot fuse is past its rating" do
      expect(protecting(minutes: 2170, coders: 3, helpers: 80).stop).to be_nil
    end

    it "names the helper share as the breaker that acts first" do
      expect(protecting(minutes: 2170, coders: 3, helpers: 80).clause).to include("helpers acts first (80 of 3 helpers)")
    end

    it "holds new coders on the machine fuse once the helpers are within their share" do
      expect(protecting(minutes: 2170, coders: 3, helpers: 2).stop)
        .to eq("skipped: breaker machine tripped: 2170 of 2160 boot minutes")
    end

    it "holds nothing while every breaker is under its rating" do
      expect(protecting(minutes: 600, coders: 3, helpers: 2).stop).to be_nil
    end

    it "keeps the boot fuse's own hold when the boot record was cut short" do
      expect(protecting(minutes: 100, coders: 3, helpers: 80, capped: true).stop).to eq("skipped: boot budget spent")
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
