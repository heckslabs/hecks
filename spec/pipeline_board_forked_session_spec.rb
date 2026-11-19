# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "json"
require "tmpdir"
require_relative "support/pipeline_board_world"

# The stand-in ledger and jobs directory of a run that forked from `old-1` to `copy-2`.
module ForkedRunReadings
  FORKED = { run: "orchestrator", session: "copy-2", forked_from: "old-1", brief: "watch", status: "started",
             agent: "orchestrator", condition: "working" }.freeze

  def ledger
    store = instance_double(Hecks::Adapters::PipelineBoard::LiveStore, records: nil)
    allow(store).to receive(:asked).with("Hecks", "AgentRun", "Running").and_return([FORKED])
    allow(store).to receive(:asked).with("Hecks", "AgentRun", "Tidyable").and_return([])
    Hecks::Adapters::PipelineTickets.new(settings: { live_store: store }).runs
  end

  # The board's session rows over a jobs directory holding the old session and its copy.
  def rows
    Dir.mktmpdir("forked-jobs") do |dir|
      { "old-1" => "done", "copy-2" => "working" }.each do |id, state|
        FileUtils.mkdir_p(File.join(dir, id))
        File.write(File.join(dir, id, "state.json"), JSON.generate(state: state))
      end
      runs = ledger
      Hecks::Adapters::PipelineJobs.new(settings: { jobs_dir: dir, runs: -> { runs }, now: -> { Time.now } }).rows
    end
  end
end

# A run whose answer's resume started a copy follows the copy (`AgentRun.Fork`, `forked_from`).
# The board reads the run's current session: the session it held before is still the run's,
# marked `superseded_by` the copy, and no role's card counts it. The ledger is a stand-in store
# and the jobs a temporary directory, so no live state is read.
RSpec.describe "The board's reading of a forked run" do
  include ForkedRunReadings

  it "keys the run by its current session, and the session it held as superseded by it", :aggregate_failures do
    runs = ledger
    expect(runs["copy-2"]).to include(run: "orchestrator", agent: "orchestrator")
    expect(runs["copy-2"]).not_to have_key(:superseded_by)
    expect(runs["old-1"]).to include(run: "orchestrator", superseded_by: "copy-2")
  end

  it "keeps the held session the run's, so it is not shown as a session no run owns" do
    expect(rows.find { |row| row[:id] == "old-1" }).to include(run: "orchestrator", superseded_by: "copy-2")
  end

  it "counts the run on its role's card once, by its current session", :aggregate_failures do
    card = Hecks::Adapters::PipelineBoard::AgentRoles.of(rows, %w[orchestrator]).first
    expect(card[:working].map { |s| s[:id] }).to eq(["copy-2"])
    expect(card[:completed]).to be_empty
  end
end
