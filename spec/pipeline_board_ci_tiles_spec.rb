# frozen_string_literal: true

require "spec_helper"
require "time"
require "hecks/pipeline_board/adapters/pipeline_stages"

# The two CI tiles that measure a landing: the commit to green, and the landed commit to the push
# CI ran for it. A landing's time comes from the journal when one was tapped, else the commit's.
RSpec.describe Hecks::Adapters::PipelineBoard::Metrics do
  let(:now) { Time.parse("2026-11-02T11:00:00Z") }
  let(:run) do
    { id: 1, sha: "a1b2c3d", started: "2026-11-02T10:00:00Z", wall_minutes: 5.0, status: "completed",
      conclusion: "success", failed_jobs: 0, pushed: "2026-11-02T10:02:00Z" }
  end

  def tile(data, id) = described_class.ci(data, [run], now).find { |found| found[:id] == id }

  it "measures landed to pushed from the landing's time to the push run's creation" do
    data = { landed_times: { "a1b2c3d" => "2026-11-02T09:50:00Z" }, commit_times: {} }
    expect(tile(data, "carry")[:value]).to eq(12.0)
  end

  it "measures commit to green from the landing to the run's finish", :aggregate_failures do
    data = { landed_times: { "a1b2c3d" => "2026-11-02T09:50:00Z" }, commit_times: {} }
    expect(tile(data, "lead")[:value]).to eq(15.0)
    expect(tile(data, "lead")[:detail]).to eq("landed to green")
  end

  it "falls back to the commit time when no landing was tapped for the sha" do
    data = { landed_times: {}, commit_times: { "a1b2c3d" => "2026-11-02T09:55:00Z" } }
    expect(tile(data, "lead")[:value]).to eq(10.0)
  end

  it "leaves the landed-to-pushed tile empty when the run carries no push time" do
    data = { landed_times: { "a1b2c3d" => "2026-11-02T09:50:00Z" }, commit_times: {} }
    run[:pushed] = nil
    expect(tile(data, "carry")[:value]).to be_nil
  end
end
