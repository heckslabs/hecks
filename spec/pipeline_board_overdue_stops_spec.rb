# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_stages/strip"

# A stop that stays open past the `stopped_run_overdue_hours` setting reaches the top of the
# board: the "Overdue for you" row names its run, stage, age and reason, ahead of the red flag,
# and the "Stopped runs" row keeps only the stops under the bound.
module OverdueStopHelpers
  NOW = Time.utc(2026, 11, 10, 20, 0, 0)

  def stop(key, reason = "quick gate red\nmore")
    { finding: key, stage: "verifying", commit: key, body: reason }
  end

  def reported(hours_ago) = (NOW - (hours_ago * 3600)).iso8601

  def strip(runs, times)
    Hecks::Adapters::PipelineBoard::Strip.build({ stopped_runs: runs, stopped_times: times }, NOW)
  end

  def row(rows, name) = rows.find { |candidate| candidate[:name] == name }
end

RSpec.describe "the board's overdue stopped runs" do
  include OverdueStopHelpers

  it "puts a stop past the bound first, with its run, stage, age and reason", :aggregate_failures do
    rows = strip([stop("abc1234567890")], { "abc1234567890" => reported(5) })
    expect(rows.first).to include(name: "Overdue for you", state: "failed", count: "1")
    expect(rows.first[:detail]).to eq("abc1234567 at verifying for 5.0 h: quick gate red")
  end

  it "keeps a stop under the bound in the Stopped runs row and out of the overdue one", :aggregate_failures do
    rows = strip([stop("new1")], { "new1" => reported(1) })
    expect(row(rows, "Overdue for you")).to be_nil
    expect(row(rows, "Stopped runs")).to include(count: "1")
  end

  it "splits the stops by their age when both kinds are open", :aggregate_failures do
    rows = strip([stop("old1"), stop("new1")], { "old1" => reported(9), "new1" => reported(2) })
    expect(row(rows, "Overdue for you")[:detail]).to start_with("old1 at verifying for 9.0 h")
    expect(row(rows, "Stopped runs")[:detail]).to start_with("new1 at verifying")
  end

  it "leaves a stop whose report time cannot be read in the Stopped runs row" do
    expect(row(strip([stop("lost")], { unknown: "no log" }), "Stopped runs")).to include(count: "1")
  end
end
