# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_stages"

# The board's newer readings: the `SignalSays`, `FillSide` and `OutcomeState` rows give the
# words and states, and the adapter only shapes what the owners answered.
RSpec.describe Hecks::Adapters::PipelineBoard::BoardReads, ".build" do
  let(:at)    { "2026-11-20T14:00:00Z" }
  let(:fill)  { { skipped: [{ slug: "a-item", reason: "load guard" }] } }
  let(:facts) { { signal: { band: "normal", load: 12.0, mark: 20.5, since: "" }, side: "admission", fill: fill } }

  def built(extra = {}) = described_class.build(facts.merge(extra), at)

  it "says a clear signal in plain words against Signalbox's mark" do
    expect(built[:signal]).to include(state: "ok", note: "Clear: admitting, load 12.0 of 20.5")
  end

  it "says a short signal as danger since the time it began" do
    short = { band: "short", load: 25.0, mark: 20.5, since: "14:02" }
    expect(built(signal: short)[:signal][:note]).to start_with("Danger: not admitting since 14:02")
  end

  it "explains a skipped item in admission's words and says which side decides" do
    said = { work: "a-item", reason: "Admission (Signalbox) is deciding: load guard", side: "admission" }
    expect(built).to include(deciding: "admission", fill_why: [said])
  end

  it "explains a skipped item in the old dispatch's words while admission is off" do
    expect(built(side: "dispatch")[:fill_why].first[:reason]).to eq("The dispatch is deciding: load guard")
  end

  it "says a red episode in one line" do
    episode = { began: "14:02", minutes: 35, culprit: "abc1234", work: "w", ending: "reverted" }
    expect(built(episodes: [episode])[:red_episodes].first).to include(line: "14:02, 35 min, culprit abc1234, reverted")
  end

  it "says a standing episode as standing" do
    episode = { began: "14:02", minutes: 3, culprit: "abc", work: "", ending: "" }
    expect(built(episodes: [episode])[:red_episodes].first[:ending]).to eq("standing")
  end

  it "draws a measure and an epic by their outcome" do
    read = [{ name: "two-branches-land", value: 3, outcome: "met", note: "" }]
    expect([built(measures: read)[:measures].first[:state], built(epics: read)[:epics].first[:key]])
      .to eq(["ok", "epic_two-branches-land"])
  end

  it "says a failed read once, as a reading in state unknown with its reason" do
    failed = built(measures: { unknown: "no event tap" }, signal: { unknown: "no signal" })
    notes = [failed[:measures], failed[:signal]].map { |row| [row].flatten.first[:note] }
    expect(notes).to eq(["unknown: no event tap", "unknown: no signal"])
  end

  it "says the holds, and an unread hold as unknown" do
    expect(built(holds: { unknown: "no store" })[:holds].first).to include(state: "unknown", note: "unknown: no store")
  end
end
