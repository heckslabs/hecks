# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_web"
require_relative "support/snapshot_freeze_world"

# The board's held state when a read fails: the reading thread survives, the failure is recorded,
# the state says how old it is, and the page carries a banner for a stale one.
RSpec.describe Hecks::Adapters::PipelineBoard::Snapshot do
  include SnapshotFreezeWorld

  after { @snap&.stop }

  it "records the error of a failed read" do
    expect(after_failed_read[:refresh_error]).to eq("RuntimeError: gh exploded")
  end

  it "keeps reading after a failed read and holds the later state" do
    expect(after_recovery).to include(generated_at: "good", refresh_error: nil)
  end

  it "says how old the last good read is without flagging a young one" do
    expect(aged_by(15)).to include(stale_seconds: 15, stale: false)
  end

  it "flags a state older than twice the period" do
    expect(aged_by(25)).to include(stale_seconds: 25, stale: true)
  end

  it "marks the placeholder stale when no read ever succeeds" do
    snapshot(-> { raise "never" })
    tick(30)
    expect(@snap.latest).to include(stale: true, ci_runs: described_class::WAITING)
  end

  it "ships a banner on the page that shows when the state is stale" do
    page = File.read(Hecks::Adapters::PipelineWeb::PAGE)
    expect(page).to include('id="stale-banner"', "banner.hidden = !s.stale")
  end
end
