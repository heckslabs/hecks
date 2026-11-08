require "spec_helper"
require_relative "support/roll_forward_fixtures"

# The clock's beat is the timer that drives a sweep of the started sessions: each beat of the
# Heartbeat asks SessionSweep for one check of every run, so no separate driver is needed.
RSpec.describe "the sweep of started sessions on each beat" do
  include RollForwardFixtures

  def beat_events
    registry = boot_hecks_in_memory(File.expand_path("../lib/hecks/hecks", __dir__)).registry
    Hecks::Runtime::AdapterLookup.standing_in(->(_port, _asked) { rolling({}) }) do
      Hecks::Runtime::Dispatcher.new(registry).dispatch_flat("Hecks::Heartbeat.Beat", beat: { value: "beat-1" })
    end
    registry.event_log.map(&:name)
  end

  it "asks for a sweep when the clock beats" do
    expect(beat_events).to include("SweepRequested")
  end
end
