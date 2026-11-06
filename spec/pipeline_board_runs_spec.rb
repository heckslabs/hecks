# frozen_string_literal: true

require "spec_helper"
require_relative "support/pipeline_board_world"

# The AgentRun records the board links to sessions: read through the launcher when the board is told
# where the live store is, so a session shows the run and the agent behind it.
RSpec.describe Hecks::Adapters::PipelineTickets do
  let(:probe) { Hecks::Adapters::PipelineBoard::Probe }
  let(:running) do
    [{ "run" => "r1", "session" => "s1", "brief" => "ROW: w1\nOUTCOME: x", "status" => "started", "agent" => "architect" }]
  end
  let(:finished) { [{ "run" => "r2", "session" => "s2", "brief" => "plan", "status" => "finished", "agent" => nil }] }

  def runs_through_launcher
    allow(probe).to receive(:json) { |_, query, **| query == "AgentRun.running" ? running : finished }
    stub_const("ENV", ENV.to_h.merge("PIPELINE_BOARD_LAUNCHER_ROOT" => "/live"))
    described_class.new.runs
  end

  it "keys each run by its session and keeps the agent and the work item", :aggregate_failures do
    runs = runs_through_launcher
    expect(runs["s1"]).to include(run: "r1", agent: "architect", work_item: "w1", status: "started")
    expect(runs["s2"]).to include(run: "r2", agent: "", status: "finished")
  end
end
