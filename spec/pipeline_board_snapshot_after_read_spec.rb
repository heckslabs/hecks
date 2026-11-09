# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_web"
require_relative "support/snapshot_freeze_world"

# The check that runs after each read, such as the restart of a board grown too large, can fail
# without ending the reading thread: the failure is recorded and the next read still happens.
RSpec.describe Hecks::Adapters::PipelineBoard::Snapshot do
  include SnapshotFreezeWorld

  after { @snap&.stop }

  def checking(check)
    reads = []
    source = -> { { generated_at: reads.push(1).size.to_s } }
    @snap = described_class.new(source: source, every: 10, now: -> { clock.first }, after_read: check).start
  end

  it "records a check that raises" do
    checking(-> { raise "exec failed" })
    until_held { @snap.latest[:refresh_error] }
    expect(@snap.latest[:refresh_error]).to eq("RuntimeError: exec failed")
  end

  it "reads again after a check that raised", :aggregate_failures do
    checking(-> { raise "exec failed" })
    until_held { @snap.latest[:refresh_error] }
    @snap.refresh_now
    until_held { @snap.latest[:generated_at] == "2" }
    expect(@snap.latest[:generated_at]).to eq("2")
  end
end
