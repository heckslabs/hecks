require "spec_helper"
require_relative "support/roll_forward_fixtures"

# A beat that finds nothing changed starts no fill: a sweep rolls only through the events that free
# capacity, and the machine rolls only when a state crossed a mark.
RSpec.describe "a quiet heartbeat" do
  include RollForwardFixtures

  def bluebook
    registry = boot_hecks_in_memory(File.expand_path("../lib/hecks/hecks", __dir__)).registry
    registry.bluebook("Hecks")
  end

  def beat_names
    registry = boot_hecks_in_memory(File.expand_path("../lib/hecks/hecks", __dir__)).registry
    Hecks::Runtime::AdapterLookup.standing_in(->(_port, _asked) { rolling({}) }) do
      Hecks::Runtime::Dispatcher.new(registry).dispatch_flat("Hecks::Heartbeat.Beat", beat: { value: "beat-1" })
    end
    registry.event_log.map(&:name)
  end

  it "sweeps the started runs", :aggregate_failures do
    names = beat_names

    expect(names).to include("SweepRequested")
    expect(names).not_to include("RollRequested")
  end

  it "has no policy that rolls on a sweep alone" do
    expect(bluebook.policies.map(&:name)).not_to include("RollWhenSwept")
  end

  it "still rolls when a run ends or the machine moves", :aggregate_failures do
    names = bluebook.policies.map(&:name)

    expect(names).to include("RollWhenARunEnds", "RollWhenARunFails", "RollWhenARunIsRetired")
    expect(names).to include("RollWhenTheMachineMoves")
  end
end
