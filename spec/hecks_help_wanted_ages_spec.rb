require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/help_wanted_looks"

# A helper's report never closes a call for help: a finished helper with the block still in the
# view leaves it assigned, the Lead may dispatch again, and a block that comes back after a
# close is recruited for again under the same key.
RSpec.describe "HelpWanted after a helper" do
  include_context "with a stall watch tap"
  include HelpWantedLooks

  before do
    write_sources(ImpedimentLooks::STANDING)
    raise_help
  end

  it "stays open when its helper finished and the block still stands", :aggregate_failures do
    assign("dispatch")
    append("SessionFinished", "help-#{HelpWantedLooks::HOLD}", "Hecks::AgentRun", 0)
    look("look-1")

    expect(field(:status)).to eq("assigned")
    expect(events_named("HelpWantedClosed")).to eq(0)
  end

  it "starts a second run when the Lead dispatches again after the first helper ended" do
    assign("dispatch")
    dispatch("Hecks::AgentRun.Decline", run: { value: "help-#{HelpWantedLooks::HOLD}" }, refusal: "gone")

    expect { assign("dispatch") }.to change { events_named("AgentRunRequested") }.by(1)
  end

  it "takes a new call for a block that came back, and keeps the closed one", :aggregate_failures do
    release
    look("look-1")
    raise_help

    expect(field(:status)).to eq("open")
    expect(field(:status, "help-#{HelpWantedLooks::HOLD}~1")).to eq("closed")
  end
end
