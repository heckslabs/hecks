# frozen_string_literal: true

require "spec_helper"
require_relative "support/pipeline_board_world"
require "hecks/pipeline_board/adapters/pipeline_web"

# What /api/runs/<run> answers: the AgentRun record and the commits its Work item landed.
RSpec.describe Hecks::Adapters::PipelineBoard::RunDetail do
  let(:records) do
    [{ run: "r-9", session: "s-9", brief: "WORK ITEM: w-9\nbody", status: "finished", detail: "report", agent: "coder",
repo: "/r" }]
  end
  let(:landings) do
    [{ branch: "qa/w-9", landed: "abc1234", status: "landed" }, { branch: "other", landed: "zzz", status: "landed" }]
  end
  let(:tickets) do
    Hecks::Adapters::PipelineTickets.new(settings: { landings: landings }).tap do |found|
      allow(found).to receive(:run_records).and_return(records)
    end
  end

  it "reads a run by its key with the commits its Work item landed", :aggregate_failures do
    detail = tickets.run_detail("r-9")
    expect(detail).to include(work: "w-9", detail: "report", landed: ["abc1234"])
  end

  it "reads a run by its session id" do
    expect(tickets.run_detail("s-9")[:run]).to eq("r-9")
  end

  it "answers nil for a key no run has" do
    expect(tickets.run_detail("none")).to be_nil
  end
end
