require "spec_helper"
require_relative "support/roll_switch_events"

# The world is read at every event, so the first one after the owner turns the switch on rolls,
# with no restart, and the end of the pause is recorded once.
RSpec.describe "a roll while the owner's switch is on", :aggregate_failures do
  include RollSwitchEvents

  before { Hecks::Adapters::Dispatching::LastRoll.reset! }

  it "requests a roll, and records its end, when a run ends" do
    world[:roll_forward] = true
    end_run("run-1")

    expect(names).to include("SessionFinished", "RollRequested")
    expect(names).to include("RollAnswered").or include("RollDeclined")
    expect(names).not_to include("RollPaused")
  end

  it "rolls again at the first event after the switch is turned on, in the same process" do
    plan("item-1")
    world[:roll_forward] = true
    %w[item-2 item-3].each { |key| plan(key) }

    expect(names.count("RollResumed")).to eq(1)
    expect(names.count("RollRequested")).to eq(2)
  end

  it "refuses no reaction on the way to the first roll" do
    world[:roll_forward] = true
    plan("item-1")

    expect(hecks.reactions.filter_map { |row| row[:reason] }).to be_empty
  end
end
