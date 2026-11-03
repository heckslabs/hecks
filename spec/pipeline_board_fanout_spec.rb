# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_stages"

# The fan-out flags. The real finding of 2026-11-02: hand-dispatched rows carry no claimed_by, so a
# dry run of Dispatch.Fill would start a second session on a row whose work already landed.
RSpec.describe Hecks::Adapters::PipelineBoard::Fanout do
  def row(slug, area = [], claimed = "") = { slug: slug, status: "planned", area: area, claimed_by: claimed, claimed_at: "" }

  def session(id, work) = { id: id, name: id, status: "busy", row: work }

  def flags(sessions, work, landed: [], fill: nil)
    mapped = described_class.mapping(sessions: sessions, work: work, landed: landed, fill: fill)
    described_class.flags_of(mapped)
  end

  let(:fill) { { would_start: [{ slug: "dynamic-shard-planning", title: "x" }], skipped: [] } }

  it "flags a session running on a row nobody claimed" do
    found = flags([session("s1", "pipeline-board")], [row("pipeline-board")])
    expect(found.map { |flag| flag[:kind] }).to eq(["unclaimed"])
  end

  it "does not flag a claimed row" do
    expect(flags([session("s1", "a")], [row("a", [], "s1")])).to be_empty
  end

  it "flags two sessions on one row" do
    found = flags([session("s1", "a"), session("s2", "a")], [row("a", [], "s1")])
    expect(found.map { |flag| flag[:kind] }).to eq(["duplicate"])
  end

  it "flags busy sessions on rows with overlapping areas", :aggregate_failures do
    found = flags([session("s1", "a"), session("s2", "b")], [row("a", ["lib/x"], "s1"), row("b", ["lib/x/y"], "s2")])
    expect(found.map { |flag| flag[:kind] }.uniq).to eq(["overlap"])
    expect(found.size).to eq(2)
  end

  it "flags a landed row still planned and says Dispatch.Fill would start another session on it", :aggregate_failures do
    found = flags([], [row("dynamic-shard-planning")], landed: ["dynamic-shard-planning"], fill: fill)
    expect(found.map { |flag| flag[:kind] }).to eq(["landed"])
    expect(found.first[:detail]).to include("Dispatch.Fill would start another session")
  end

  it "does not flag a planned row that has not landed" do
    expect(flags([], [row("other")], landed: ["x"], fill: fill)).to be_empty
  end
end
