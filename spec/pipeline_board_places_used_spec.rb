# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_stages"
require_relative "support/board_rows"

# The board states the places used against the cap, and why the last fill skipped, by kind.
RSpec.describe Hecks::Adapters::PipelineBoard::PlacesUsed do
  include BoardRows

  def fill(skipped, cap: 6, headroom: 2)
    { cap: cap, headroom: headroom, started: 0, skipped: skipped.map { |reason| { slug: "w", reason: reason } } }
  end

  def kinds(*reasons) = described_class.of(fill(reasons))[:skips].to_h { |skip| skip.values_at(:kind, :count) }

  it "states the places used, the cap and the places free", :aggregate_failures do
    row = described_class.of(fill([]))
    expect(row.values_at(:used, :cap, :free)).to eq([4, 6, 2])
  end

  it "reads a skip for the cap as cap" do
    expect(kinds("skipped: cap 6 reached")).to eq("cap" => 1)
  end

  it "reads a skip for memory as memory" do
    expect(kinds("skipped: memory low")).to eq("memory" => 1)
  end

  it "reads a skip for an area another item holds as area overlap" do
    expect(kinds("skipped: overlaps lib/a held by x")).to eq("area overlap" => 1)
  end

  it "reads a skip for a waiting item as dependency, counting each" do
    expect(kinds("skipped: waits on a", "skipped: waits on b")).to eq("dependency" => 2)
  end

  it "reads an unread fill as no places, its reason said" do
    expect(described_class.of({ unknown: "no fill" })).to include(used: 0, cap: 0, free: 0, note: "unknown: no fill")
  end

  it "is a row the bluebook accepts as PlacesUsed" do
    expect(built("PlacesUsed", described_class.of(fill(["skipped: cap 6 reached"])))).to include(cap: 6)
  end

  it "rides the Snapshot as places_used" do
    expect(Hecks::Adapters::PipelineBoard::BoardReads.build({ fill: fill([]) }, "t")[:places_used]).to include(cap: 6)
  end
end
