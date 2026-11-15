# frozen_string_literal: true

require "spec_helper"

require "hecks/pipeline_board/adapters/pipeline_stages"

# The board's throughput chart: the Work items finished on each of the last days, read from the
# Tickets store's own event log, with today last and the average of the days before it.
RSpec.describe Hecks::Adapters::PipelineBoard::ThroughputDays do
  let(:now) { Time.new(2026, 11, 14, 9, 0, 0, "-07:00") }
  let(:times) { %w[2026-11-14T15:00:00Z 2026-11-14T08:00:00Z 2026-11-13T20:00:00Z 2026-11-01T12:00:00Z 2026-10-01T12:00:00Z] }
  let(:built) { described_class.build(times, now) }

  def finished_on(day) = built[:days].find { |row| row[:day] == day }&.fetch(:finished)

  it "shows the last fourteen days, oldest first and today last" do
    expect(built[:days].map { |row| row[:day] }.values_at(0, -1)).to eq(%w[2026-11-01 2026-11-14])
  end

  it "counts a finish on the board's own calendar day, not the day in UTC", :aggregate_failures do
    expect(finished_on("2026-11-14")).to eq(2)
    expect(finished_on("2026-11-13")).to eq(1)
  end

  it "shows a day nothing finished on as zero" do
    expect(finished_on("2026-11-05")).to eq(0)
  end

  it "leaves out a finish older than the days shown" do
    expect(built[:days].sum { |row| row[:finished] }).to eq(4)
  end

  it "averages the days before today, since today is still open" do
    expect(described_class.build(Array.new(26) { "2026-11-10T12:00:00Z" } + times, now)[:average]).to eq(2)
  end

  it "labels a day with its weekday and date" do
    expect(built[:days].last[:label]).to eq("Sat 14")
  end

  it "hands back a reading that failed as it was read" do
    expect(described_class.build({ unknown: "no store" }, now)).to eq({ unknown: "no store" })
  end

  it "skips a time that cannot be read" do
    expect(described_class.build(["not a time"], now)[:days].sum { |row| row[:finished] }).to eq(0)
  end

  # A day on the board is an Arizona day: it begins at midnight in Arizona, which is seven in the
  # morning in UTC, never at midnight UTC (five in the afternoon there).
  context "when the days are counted in Arizona time" do
    it "is still the day before at 5:30 PM Arizona time, though UTC has turned over" do
      days = described_class.build(["2026-11-15T00:10:00Z"], Time.utc(2026, 11, 15, 0, 30, 0))[:days]

      expect([days.last[:day], days.last[:finished]]).to eq(["2026-11-14", 1])
    end

    it "turns over at midnight Arizona time" do
      days = described_class.build([], Time.utc(2026, 11, 15, 7, 0, 1))[:days]

      expect(days.last[:day]).to eq("2026-11-15")
    end
  end
end
