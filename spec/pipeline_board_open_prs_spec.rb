# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_stages"

# The Open PRs metric: the GitHub reader's count of open pull requests, and the tile built from it.
# The reader is handed a fake `gh`, so no repository is read.
RSpec.describe "the Open PRs metric" do
  let(:now) { Time.parse("2026-11-09T12:00:00Z") }
  let(:tiles) { Object.new.extend(Hecks::Adapters::PipelineBoard::PrTiles) }

  def row(number, branch, hours)
    { "number" => number, "headRefName" => branch, "statusCheckRollup" => [],
      "createdAt" => (now - (hours * 3600)).utc.iso8601 }
  end

  def reading(listed)
    gh = ->(*_args) { listed }
    Hecks::Adapters::PipelineGitHub.new(settings: { gh: gh, settled_path: nil }).open_prs
  end

  def tile_of(listed) = tiles.open_prs(reading(listed), now)

  it "reads none open", :aggregate_failures do
    expect(reading([])).to include(count: 0, oldest: nil, train: nil)
    expect(tile_of([])).to include(value: 0, state: "ok", detail: "none open")
  end

  it "reads one open train PR", :aggregate_failures do
    expect(reading([row(7, "train/main-abc", 5)])).to include(count: 1, train: 7)
    expect(tile_of([row(7, "train/main-abc", 5)])).to include(value: 1, unit: "open", detail: "oldest 5.0 h; train PR #7")
  end

  it "reads three open PRs, the oldest and the newest train PR", :aggregate_failures do
    listed = [row(3, "feature/a", 30), row(9, "train/main-x", 2), row(8, "train/main-y", 10)]
    expect(reading(listed)).to include(count: 3, train: 9)
    expect(tile_of(listed)).to include(value: 3, detail: "oldest 30.0 h; train PR #9")
  end

  it "asks for attention once the oldest has waited the stale hours" do
    expect(tile_of([row(3, "feature/a", 24)])).to include(state: "attention")
  end

  it "says no train PR is open when none is on a train branch" do
    expect(tile_of([row(3, "feature/a", 1)])[:detail]).to eq("oldest 1.0 h; no train PR")
  end

  it "marks a count cut off by the list limit" do
    listed = Array.new(30) { |index| row(index + 1, "feature/#{index}", 1) }
    expect(tile_of(listed)).to include(value: 30, unit: "open (limit)")
  end

  it "says why when the reader failed" do
    expect(tiles.open_prs({ unknown: "gh down" }, now)).to include(state: "unknown", detail: "unknown: gh down")
  end

  it "is among the board's metrics" do
    data = { open_prs: { count: 2, oldest: now.iso8601, train: nil, capped: false } }
    ids = Hecks::Adapters::PipelineBoard::Metrics.tiles(data, now).map { |tile| tile[:id] }
    expect(ids).to include("open_prs")
  end
end
