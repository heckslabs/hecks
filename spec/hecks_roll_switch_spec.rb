require "spec_helper"
require_relative "support/roll_switch_events"

# The owner's switch is read before a roll is requested. While it is off the events that would
# roll request none, so the Rolling port's own paused refusal is never reached, and the pause is
# recorded once.
RSpec.describe "a roll while the owner's switch is off", :aggregate_failures do
  include RollSwitchEvents

  before { Hecks::Adapters::Dispatching::LastRoll.reset! }

  it "requests no roll when a run ends" do
    end_run("run-1")

    expect(names).to include("SessionFinished", "RollPaused")
    expect(names).not_to include("RollRequested", "RollRefused", "RollDeclined")
  end

  it "records one pause across several events, with the reason" do
    end_run("run-1")
    %w[item-1 item-2].each { |key| plan(key) }

    expect(names.count("RollPaused")).to eq(1)
    expect(switch_record[:reason][:value]).to include("dispatch_roll_forward is false")
  end
end
