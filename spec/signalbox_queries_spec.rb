# frozen_string_literal: true

require "spec_helper"
require "support/signalbox_asks"

# What a reader asks Signalbox through its declared queries: the newest reading with the marks it
# was judged against, the band the machine stands in, and why a work item was held.
RSpec.describe "Signalbox's queries" do
  include SignalboxAsks

  let(:marks) { Hecks::Adapters::Looking::Marks.new(nil).facts }

  it "answers the newest reading with the load marks the beat judged it against" do
    begin_beat("beat-1")
    row = ask("Pressure.Latest").first

    expect([plain(row, :load_tight), plain(row, :load_short)]).to eq(marks.values_at(:load_tight, :load_short))
  end

  it "stamps the newest reading with when it was read" do
    begin_beat("beat-1")

    expect(plain(ask("Pressure.Latest").first, :read_at)).to be_within(60).of(Time.now.to_i)
  end

  it "keeps one standing for the machine across beats" do
    %w[beat-1 beat-2].each { |key| begin_beat(key) }

    expect(ask("Standing.Now").map { |row| plain(row, :band) }).to eq(["normal"])
  end

  it "says why a work item was held, the newest ruling first" do
    hold("item:1", "item", "its area overlaps a running item", 900)
    hold("item:2", "item", "only an urgent coder is admitted while pressure is short", 960)

    expect(ask("Hold.Of", subject: { value: "item" }).map { |row| plain(row, :hold) }).to eq(%w[item:2 item:1])
  end

  it "answers the last ruling that held a session" do
    hold("item:1", "item", "its area overlaps a running item", 900)
    hold("other:1", "other", "at most the ramp step starts in one ramp window", 960)

    expect(plain(ask("Hold.Last").first, :reason)).to eq("at most the ramp step starts in one ramp window")
  end
end
