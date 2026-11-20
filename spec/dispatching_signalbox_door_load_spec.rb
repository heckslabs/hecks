# frozen_string_literal: true

require "spec_helper"
require_relative "support/signalbox_door_wiring"

# The door answers the load its band was judged on: its own beat's, or the posted signal's.
RSpec.describe Hecks::Adapters::Dispatching::SignalboxDoor do
  include SignalboxDoorWiring

  let(:loaded) { posted.merge(band: "short", load: 1900, cores: 6) }

  it "answers its own cleared beat's load, cores and load marks" do
    held = door
    expect(wired { held.look }).to include(load: 700, cores: 6, load_tight: 150, load_short: 342)
  end

  it "answers the posted signal's load and cores from a worktree's view" do
    held = door(view: SignalboxDoorWiring::WORKTREE, signal: loaded)
    expect(wired { held.look }).to include(band: "short", load: 1900, cores: 6)
  end
end
