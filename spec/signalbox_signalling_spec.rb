# frozen_string_literal: true

require "spec_helper"
require "hecks/signalbox/adapters/signalling"
require "hecks/signalbox/adapters/replayed_looking"
require "hecks/signalbox/adapters/replayed_pressure_posting"

# The clock's beat begins Signalbox's pressure beat through the Hecks domain's `Signalling` port
# (ADR 0222, phase 3b): Hecks attaches Signalbox, so one beat of the clock looks, clears and posts
# the machine's one signal on the shared bus.
RSpec.describe Hecks::Adapters::Signalling do
  let(:registry) { boot_hecks_in_memory.registry }

  before { Hecks::Adapters::ReplayedPressurePosting.posted.clear }

  def wiring
    stand_ins = { "Looking" => Hecks::Adapters::ReplayedLooking.new, "PressurePosting" => Hecks::Adapters::ReplayedPressurePosting.new,
                  "Signalling" => described_class.new(registry: registry) }
    ->(port, _asked) { stand_ins.fetch(port.to_s) { Struct.new(:x).new } }
  end

  def beat(key)
    Hecks::Runtime::AdapterLookup.standing_in(wiring) do
      Hecks::Runtime::Dispatcher.new(registry).dispatch_flat("Hecks::Heartbeat.Beat", beat: { value: key })
    end
  end

  it "posts the quiet machine's settled pressure on the clock's beat", :aggregate_failures do
    beat("beat-quiet")
    expect(Hecks::Adapters::ReplayedPressurePosting.posted.map { |held| held[:band] }).to eq(["normal"])
    expect(Hecks::Adapters::ReplayedPressurePosting.posted.first[:coders_fit]).to include(value: 5)
  end

  it "posts the short band with no room in the helper storm" do
    beat("beat-storm")
    expect(Hecks::Adapters::ReplayedPressurePosting.posted.first[:coders_fit]).to include(value: 0)
  end

  it "is refused where Signalbox is not attached" do
    detached = instance_double(Hecks::Runtime::Registry, bluebooks: {})
    expect { described_class.new(registry: detached).signal(beat: "b") }.to raise_error(described_class::Unsignalled)
  end
end
