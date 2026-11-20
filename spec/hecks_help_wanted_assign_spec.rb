require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/help_wanted_looks"

# The Lead reads the unassigned calls for help and assigns each to an idle run or a new one;
# the owner's help is never assigned.
RSpec.describe "HelpWanted assigning" do
  include_context "with a stall watch tap"
  include HelpWantedLooks

  before { write_sources(ImpedimentLooks::STANDING) }

  it "answers the idle run the Lead assigns it to", :aggregate_failures do
    a_started_run("helper-1")
    raise_help
    assign("idle")

    expect(events_named("AnswerRequested")).to eq(1)
    expect(%i[status helper].map { |name| field(name) }).to eq(%w[assigned helper-1])
  end

  it "starts one run of its role, under its own key, when the Lead dispatches it" do
    raise_help
    expect { assign("dispatch") }.to change { keys("Hecks", "AgentRun", :run) }.to(["help-#{HelpWantedLooks::HOLD}"])
  end

  it "never assigns the owner's help" do
    raise_help(HelpWantedLooks::HOLD, "owner")
    expect { assign("idle") }.to raise_error(/asked on the board, never assigned/)
  end
end
