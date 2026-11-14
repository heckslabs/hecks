require "spec_helper"
require_relative "support/landing_pace_scratch"

RSpec.describe Hecks::Adapters::LandingPaceReading do
  include LandingPaceScratch

  let(:rows) { LandingPaceScratch::ROWS }

  it "counts the landings of each UTC day, a day without one as zero" do
    expect(pace_of(rows)).to include("  2026-11-01  2\n  2026-11-02  0\n  2026-11-03  1")
  end

  it "totals the landings of both Landing names and no other aggregate's" do
    expect(pace_of(rows)).to include("landed: 3 in 3 days: mean 1.0 a day, median 1.0, busiest 2 on 2026-11-01")
  end

  it "counts the refusals" do
    expect(pace_of(rows)).to include("refused: 1")
  end

  it "says so when the window holds no landing" do
    expect(pace_of(rows, days: 1)).to start_with("no landing is recorded in the last 1 days of ")
  end

  it "says there is no ledger when Landing is not kept in a SQLite file" do
    expect(described_class.new.pace[:text]).to eq(described_class::NO_LEDGER)
  end
end
