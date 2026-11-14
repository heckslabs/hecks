require "spec_helper"
require_relative "support/landing_pace_scratch"

RSpec.describe Hecks::Adapters::LandingPaceReading::Pairing do
  include LandingPaceScratch

  let(:rows) { LandingPaceScratch::ROWS }

  it "measures the wait from the first request for the branch, through a refusal, and from a finish's own run" do
    expect(pace_of(rows)).to include("ready to landed, 2 landings: median 30s, p90 5m 0s, longest 5m 0s")
  end

  it "names the landings no request was found for" do
    expect(pace_of(rows)).to include("no request in the window for 1 landings: left out of the wait")
  end

  it "measures a branch that lands again from its next request" do
    expect(pace_of(rows.first(5) + LandingPaceScratch::AGAIN)).to include("median 5s, p90 5m 0s")
  end
end
