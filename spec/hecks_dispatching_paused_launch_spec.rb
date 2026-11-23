require "spec_helper"
require_relative "support/paused_launch_fixtures"

# A paused fill starts no session: the owner's pause is read before a coder is dispatched, so a
# work item whose start was stopped by the pause is yielded without an `AgentRun`, and a pause that
# lands mid-fill leaves the work items not yet started waiting in the plan.
RSpec.describe "a paused fill", :aggregate_failures do
  include PausedLaunchFixtures

  it "launches no run for a work item whose start the pause stopped, and yields it" do
    report = confirmed(fill_with(recording(stop_start: true)), only: { value: "zz-named" })

    expect(report).to include("yielded zz-named", "new work is stopped")
    expect(verbs).not_to include("AgentRun.dispatch!")
  end

  it "launches no run and yields nothing for a work item left waiting when the pause lands mid-fill" do
    allow(Hecks::Adapters::WorkLimits).to receive(:switch_on?).and_return(true, false)
    report = confirmed(fill_with(recording))

    expect(report).to include("waits: new work is stopped")
    expect(verbs).not_to include("AgentRun.dispatch!", "Work.start!", "Work.yield!")
  end
end
