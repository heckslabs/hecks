# frozen_string_literal: true

require "spec_helper"
require "support/reaping_fleet"
require "support/reap_turn"

# `ReapTurn` spaces the reaps the clock's beat starts: one on the first beat, then at most one
# every half hour, and each reap frees the turn when it ends.
RSpec.describe "The turn to reap, asked by the clock's beat" do
  include_context "with a reaping fleet"
  include_context "with a first beat at noon"

  it "reaps on the first beat and frees the turn", :aggregate_failures do
    expect(reaps).to eq(1)
    expect(delivered("FreeTheTurnWhenTheReapIsReported")).to eq(1)
  end

  it "does not reap on a beat inside half an hour of the last reap" do
    at(noon + 1799)
    beat("b2")
    expect(reaps).to eq(1)
  end

  it "reaps on a beat half an hour after the last reap" do
    at(noon + 1800)
    beat("b2")
    expect(reaps).to eq(2)
  end
end
