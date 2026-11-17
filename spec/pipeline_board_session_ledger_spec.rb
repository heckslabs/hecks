# frozen_string_literal: true

require "spec_helper"
require_relative "support/pipeline_ledger_jobs"

# The board lists sessions from the AgentRun ledger, not from a `claude agents` call. A run the
# ledger tidied leaves the list at once, so removing 50 of 85 sessions leaves 35.
RSpec.describe "The board's sessions come from the AgentRun ledger" do
  include PipelineLedgerJobs

  let(:dir) { Dir.mktmpdir("session-ledger") }

  after { FileUtils.rm_rf(dir) }

  it "lists only the sessions whose runs the ledger still holds, after 50 of 85 were tidied" do
    ids = Array.new(85) { |index| "s#{index}" }
    ids.each { |id| job(id, "done") }
    live = ids.last(35).to_h { |id| [id, { run: id, condition: "done" }] }

    expect(rows(live, now: past_window).map { |row| row[:id] }).to match_array(live.keys)
  end

  it "shows an old session whose run is not tidied, and hides an old one with no run", :aggregate_failures do
    job("kept")
    job("gone")
    found = rows({ "kept" => { run: "kept", condition: "working" } }, now: past_window)

    expect(found.map { |row| row[:id] }).to eq(["kept"])
    expect(found.first).to include(run: "kept", status: "busy")
  end
end
