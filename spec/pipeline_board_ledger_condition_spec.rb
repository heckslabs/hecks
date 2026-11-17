# frozen_string_literal: true

require "spec_helper"
require_relative "support/pipeline_ledger_jobs"

# What a run's condition says of its session on the board.
RSpec.describe "A ledger run's condition on the board" do
  include PipelineLedgerJobs

  let(:dir) { Dir.mktmpdir("session-ledger") }

  after { FileUtils.rm_rf(dir) }

  it "reads busy from a working condition and blocked from a blocked one", :aggregate_failures do
    job("w")
    job("b", "blocked", "needs" => "pick one")
    found = rows({ "w" => { run: "w", condition: "working" }, "b" => { run: "b", condition: "blocked" } })

    expect(found.to_h { |row| [row[:id], row[:status]] }).to eq("w" => "busy", "b" => "blocked")
  end

  it "carries a finished run's condition, and never starts claude agents", :aggregate_failures do
    job("f", "done")
    allow(Hecks::Adapters::PipelineBoard::Probe).to receive(:json)

    expect(rows({ "f" => { run: "f", condition: "done" } }).first).to include(status: "done", state: "done")
    expect(Hecks::Adapters::PipelineBoard::Probe).not_to have_received(:json)
  end
end
