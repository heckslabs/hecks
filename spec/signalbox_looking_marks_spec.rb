# frozen_string_literal: true

require "spec_helper"
require "hecks/signalbox/adapters/looking"
require "hecks/hecks/adapters/dispatching"

# The pressure beat reads its marks and draws from the Signalbox world, and keeps the starting value
# of any the world leaves out.
RSpec.describe Hecks::Adapters::Looking::Marks do
  let(:world) { Struct.new(:verbs) { def for_verb(name) = verbs[name] }.new(world_verbs) }
  let(:world_verbs) { { "pressure" => { target_mb: 5_000, load_short_percent: 250 }, "draws" => { coder_mb: 2_000 } } }
  let(:registry) { Struct.new(:found) { def world(_name) = found }.new(world) }

  it "reads the marks and the coder's draw the Signalbox world sets" do
    expect(described_class.new(registry).facts).to include(target: 5_000, load_short: 250, coder_draw: 2_000)
  end

  it "keeps the starting value of a mark the world leaves out" do
    expect(described_class.new(registry).facts).to include(floor: 3_072, stale_after: 120)
  end

  # The marks the Signalbox world itself declares, as the beat reads them.
  it "puts the short load mark at the fill's old guard of 20.5: 342 percent of six cores" do
    registry = boot_hecks_in_memory(Hecks::Adapters::Dispatching::SignalboxDoor::HOME).registry
    expect(described_class.new(registry).facts).to include(load_tight: 150, load_short: 342)
  end
end
