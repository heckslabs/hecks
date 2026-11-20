require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# With the owner's `admission.signalbox` switch on, a fill admits each coder through Signalbox's
# `Admission.Admit` in place of the cap and the red reserve: the givens the bluebook declares say
# who waits, and the fill only assembles the facts each admission is asked with.
RSpec.describe "admission by headroom" do
  describe Hecks::Adapters::Dispatching::Admitting do
    # A door whose beat reads 7000 MB of headroom, as on 2026-11-19, in the normal band.
    def door(band: "normal", headroom: 7000)
      beat = { band: band, headroom: headroom, floor: 3072, gap: 2048, age: 0, stale_after: 120, draw: 1536 }
      Hecks::Adapters::Dispatching::SignalboxDoor.new.tap { |held| allow(held).to receive(:look).and_return(beat) }
    end

    def item(key, priority: "next") = Hecks::Adapters::Dispatching::Plan::Item.new(key: key, title: key, priority: priority)

    def admitting(runs: {}, **beat) = described_class.new(runs: runs, now: Time.utc(2026, 11, 19, 22), door: door(**beat))

    it "admits a lower-tier coder whose draw leaves the gap above the floor" do
      expect(admitting.reason(item("tiles"))).to be_nil
    end

    it "holds the second coder of one fill to the ramp step" do
      expect(admitting(headroom: 12_000).reason(item("tiles"), chosen: 1)).to include("at most the ramp step")
    end

    it "counts a run started inside the ramp window, other than the item's own" do
      runs = { "board" => { started_at: "2026-11-19T21:59:30Z" } }
      expect(admitting(runs: runs).reason(item("tiles"))).to include("at most the ramp step")
    end

    it "holds a lower-tier coder whose draw would leave less than the gap: the cap does not flip" do
      expect(admitting(headroom: 5500).reason(item("tiles"))).to include("leaves the gap above the floor")
    end

    it "admits a priority-now coder while pressure is short, its draw fitting the headroom" do
      expect(admitting(band: "short", headroom: 2000).reason(item("fix", priority: "now"))).to be_nil
    end

    it "holds a lower-tier coder while pressure is tight: starts wait before work in flight does" do
      expect(admitting(band: "tight").reason(item("tiles"))).to include("starts while pressure is tight")
    end

    it "admits a priority-now coder while pressure is tight" do
      expect(admitting(band: "tight").reason(item("fix", priority: "now"))).to be_nil
    end

    it "holds a lower-tier coder while pressure is short" do
      expect(admitting(band: "short", headroom: 9000).reason(item("tiles"))).to include("only an urgent coder")
    end

    it "holds a coder outranked by one this fill left waiting" do
      expect(admitting.reason(item("tiles"), outranked: 1)).to include("the waiting job with the most value")
    end

    it "holds every coder while the signal is dark" do
      expect(admitting(band: "dark").reason(item("fix", priority: "now"))).to include("only the repair seat")
    end
  end

  describe Hecks::Adapters::Dispatching::Plan do
    def item(key) = described_class::Item.new(key: key, title: key, detail: "", area: [key])

    # Admits all but `held`, saying why that one waits.
    def admit(held)
      Struct.new(:held) { def reason(entry, **) = entry.key == held ? "skipped: signalbox: no room" : nil }.new(held)
    end

    def plan(admit:)
      described_class.new(%w[a b c].map { |key| item(key) }, [item("s1")], cap: 1, load: 1.0, max_load: 20.0, frozen: [],
                                                                           admit: admit)
    end

    it "starts what Signalbox admits, past a full cap" do
      expect(plan(admit: admit("none")).chosen.map(&:key)).to eq(%w[a b c])
    end

    it "leaves waiting what Signalbox does not admit, with its given" do
      expect(plan(admit: admit("b")).skipped.map(&:to_a)).to eq([["b", "skipped: signalbox: no room"]])
    end
  end

  describe Hecks::Adapters::Dispatching::AdmissionSwitch do
    def registry(world) = double(world: double(for_verb: world))

    it "is off when the world names no admission line" do
      expect(described_class.on?(registry(nil))).to be(false)
    end

    it "is on when the world says signalbox: true" do
      expect(described_class.on?(registry({ signalbox: true }))).to be(true)
    end
  end
end
