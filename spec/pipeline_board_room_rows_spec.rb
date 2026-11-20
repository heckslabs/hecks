# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_stages"

# The strip is not fixed at seven: Signalbox's signal and the explained fill are stages of it.
# A signal that does not drive and a fill that reported nothing are unread, never ok. A stuck
# item that names no one in its `StuckKind` row says who it waits on itself.
RSpec.describe Hecks::Adapters::PipelineBoard::RoomRows do
  let(:fill) { { started: 3, cap: 8, headroom: 5, would_start: [{ slug: "a" }], skipped: skipped } }
  let(:skipped) { [{ slug: "b", reason: "area held" }, { slug: "c", reason: "area held" }] }
  let(:held) { { status: "blocked", owner: false, held: "waiting on a review verdict", run: "r9", detail: "[review] ok?" } }

  it "reads the signal as unknown, with the reason, while it does not drive" do
    expect(described_class.signal(nil)).to include(state: "unknown", count: "-", detail: /does not drive/)
  end

  it "says the signal's band and what Signalbox said, in attention while it is short" do
    row = described_class.signal({ band: "short", short: true, said: "pressure short (Signalbox): 0 coders fit" })
    expect(row).to include(state: "attention", count: "short", detail: /0 coders fit/)
  end

  it "explains the fill: seats started of the cap, what would start and why the rest were skipped" do
    expect(described_class.fill(fill)).to include(state: "ok", count: "3 of 8", detail: "would start 1, skipped 2; 2 area held")
  end

  it "reads a fill that reported nothing as unknown, with the reason" do
    expect(described_class.fill({ unknown: "no fill yet" })).to include(state: "unknown", detail: "unknown: no fill yet")
  end

  it "says who a blocked run waits on from the session's own word, in the group its kind's row gives" do
    item = Hecks::Adapters::PipelineBoard::StuckRows.blocked(held)
    expect(item).to include(kind: "blocked_run", group: "waiting on a person", waits_on: "waiting on a review verdict")
  end
end
