# frozen_string_literal: true

require "spec_helper"
require_relative "support/pipeline_board_world"

# The AgentRun records the board links to sessions: read from the live store in this process when
# the board is told where it is, so a session shows the run and the agent behind it.
RSpec.describe Hecks::Adapters::PipelineTickets do
  let(:probe) { Hecks::Adapters::PipelineBoard::Probe }
  let(:running) do
    { run: "r1", session: "s1", brief: "ROW: w1\nOUTCOME: x", status: "started", agent: "architect", parent: "w1" }
  end
  let(:finished) { { run: "r2", session: "s2", brief: "plan", status: "finished", agent: nil } }
  let(:store) { instance_double(Hecks::Adapters::PipelineBoard::LiveStore, records: nil) }

  # The live store answers the declared query of an aggregate with these rows.
  def answering(aggregate, query, rows)
    allow(store).to receive(:asked).with(*aggregate.split("::"), query).and_return(rows)
  end

  def runs_from_live_store
    answering("Hecks::AgentRun", "Running", [running])
    answering("Hecks::AgentRun", "Tidyable", [finished])
    described_class.new(settings: { live_store: store }).runs
  end

  it "keys each run by its session and keeps the agent and the work item", :aggregate_failures do
    runs = runs_from_live_store
    expect(runs["s1"]).to include(run: "r1", agent: "architect", work_item: "w1", status: "started")
    expect(runs["s2"]).to include(run: "r2", agent: "", status: "finished")
  end

  it "keeps the run that dispatched each run, empty for one no run dispatched", :aggregate_failures do
    runs = runs_from_live_store
    expect(runs["s1"]).to include(parent: "w1")
    expect(runs["s2"]).to include(parent: "")
  end

  it "asks the running and tidyable queries, and never loads every run to choose among them" do
    runs_from_live_store
    expect(store).not_to have_received(:records)
  end

  it "starts no process to read them" do
    allow(probe).to receive(:json)
    allow(probe).to receive(:run)
    runs_from_live_store
    expect(probe).not_to have_received(:json)
  end

  def tickets_from_live_store
    answering("Tickets::Work", "Undone", [{ work: "w1", status: "planned" }])
    allow(store).to receive_messages(tallied: { "planned" => 1, "done" => 1 }, records: [{ status: "landed", branch: "qa/b" }])
    described_class.new(settings: { live_store: store })
  end

  it "counts every status of the live store's Work items, as the WorkByStatus read model answers" do
    expect(tickets_from_live_store.counts).to eq("planned" => 1, "done" => 1)
  end

  it "answers the live store's undone Work items as its open work" do
    open = tickets_from_live_store.open_work
    expect(open.map { |item| item[:slug] }).to eq(["w1"])
  end

  it "reads the landed branches from the live store" do
    expect(tickets_from_live_store.landed_branches).to eq(["b"])
  end
end
