# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_web"

# A fill report older than the bluebook's `fill_stale_minutes` (15) is marked stale wherever the
# page shows it: the strip's Fill row, the stale banner's sections, the fill tile's heading and
# the fan-out's fill. The `Fill age` rows decide; a report that states no time is not marked.
RSpec.describe Hecks::Adapters::PipelineBoard::FillAge do
  let(:board) { Hecks::Adapters::PipelineBoard }
  let(:fresh) { { started: 3, cap: 7, headroom: 13, at: "2026-11-20T18:33:54Z", age_minutes: 14, would_start: [], skipped: [] } }
  let(:old) { fresh.merge(age_minutes: 16) }

  it "calls a report stale past fifteen minutes, and not at fifteen or under", :aggregate_failures do
    expect(described_class.stale?(old)).to be(true)
    expect(described_class.stale?(fresh.merge(age_minutes: 15))).to be(false)
    expect(described_class.stale?(fresh)).to be(false)
  end

  it "marks neither a report that states no time nor a fill that was not read", :aggregate_failures do
    expect(described_class.stale?(fresh.merge(age_minutes: nil))).to be(false)
    expect(described_class.stale?({ unknown: "no fill yet" })).to be(false)
  end

  it "puts the strip's Fill row in attention and says the age first", :aggregate_failures do
    expect(board::RoomRows.fill(old)).to include(state: "attention", detail: /\Astale: the last fill ran 16 minutes ago; would/)
    expect(board::RoomRows.fill(fresh)).to include(state: "ok", detail: /\Awould start 0/)
  end

  it "adds the fill to the stale sections, since the time its report states", :aggregate_failures do
    expect(described_class.noted({}, old)).to eq(fill: { since: old[:at], reason: "the last fill ran 16 minutes ago" })
    expect(described_class.noted({}, fresh)).to eq({})
  end

  it "keeps the note of a fill whose read was itself skipped" do
    skipped = { fill: { since: "2026-11-20T18:00:00Z", reason: "still running" } }
    expect(described_class.noted(skipped, old)).to eq(skipped)
  end

  it "says stale in the fill tile's heading", :aggregate_failures do
    expect(board::TileHtml.fill(old)).to include("(as of 2026-11-20T18:33:54Z; stale: the last fill ran 16 minutes ago)")
    expect(board::TileHtml.fill(fresh)).to include("(as of 2026-11-20T18:33:54Z)")
  end

  it "states stale on the fan-out's fill for the page, and leaves an unread fill as it is", :aggregate_failures do
    expect(described_class.marked(old)).to include(stale: true)
    expect(described_class.marked(fresh)).to include(stale: false)
    expect(described_class.marked({ unknown: "no fill yet" })).to eq(unknown: "no fill yet")
  end
end
