# frozen_string_literal: true

require "spec_helper"
require_relative "support/pipeline_board_world"

# The AgentRun records the board links to sessions: read from the live store in this process when
# the board is told where it is, so a session shows the run and the agent behind it.
RSpec.describe Hecks::Adapters::PipelineTickets do
  let(:probe) { Hecks::Adapters::PipelineBoard::Probe }
  let(:running) do
    { run: "r1", session: "s1", brief: "ROW: w1\nOUTCOME: x", status: "started", agent: "architect" }
  end
  let(:finished) { { run: "r2", session: "s2", brief: "plan", status: "finished", agent: nil } }
  let(:store) { instance_double(Hecks::Adapters::PipelineBoard::LiveStore, records: nil) }

  def runs_from_live_store
    allow(store).to receive(:records).with("Hecks", "AgentRun").and_return([running, finished])
    described_class.new(settings: { live_store: store }).runs
  end

  it "keys each run by its session and keeps the agent and the work item", :aggregate_failures do
    runs = runs_from_live_store
    expect(runs["s1"]).to include(run: "r1", agent: "architect", work_item: "w1", status: "started")
    expect(runs["s2"]).to include(run: "r2", agent: "", status: "finished")
  end

  it "leaves out the runs that were retired or refused, as the running and tidyable queries do" do
    retired = { run: "r3", session: "s3", brief: "x", status: "retired", agent: "coder" }
    allow(store).to receive(:records).with("Hecks", "AgentRun").and_return([running, finished, retired])
    expect(described_class.new(settings: { live_store: store }).runs.keys).to eq(%w[s1 s2])
  end

  it "starts no process to read them" do
    allow(probe).to receive(:json)
    allow(probe).to receive(:run)
    runs_from_live_store
    expect(probe).not_to have_received(:json)
  end

  def tickets_from_live_store
    work = [{ work: "w1", status: "planned", title: "t" }, { work: "w2", status: "done", title: "u" }]
    allow(store).to receive(:records).with("Tickets", "Work").and_return(work)
    allow(store).to receive(:records).with("Hecks", "Landing").and_return([{ status: "landed", branch: "qa/b" }])
    described_class.new(settings: { live_store: store })
  end

  it "counts the undone Work items of the live store" do
    expect(tickets_from_live_store.counts).to eq("planned" => 1)
  end

  it "reads the landed branches from the live store" do
    expect(tickets_from_live_store.landed_branches).to eq(["b"])
  end
end
