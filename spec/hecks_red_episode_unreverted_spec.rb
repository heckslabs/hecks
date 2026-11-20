require "spec_helper"
require_relative "support/red_episode_helpers"

# A red episode is the whole record of one stretch of red main: when it began, when it ended and
# how. Every time is passed in, since the bluebook reads no clock, and everything runs in Memory.
RSpec.describe "a red episode with no revert of its own" do
  include_context "with red episodes in Memory"

  it "ends declined as it begins when every merge is acquitted" do
    acquitted("e1", at: 100)
    expect(ended("e1")).to eq(["declined", 100, 100])
  end

  it "stands parked until the flag is lowered, then reads fixed", :aggregate_failures do
    parked("e1", at: 100)
    expect(ended("e1")).to eq(["parked", 100, 0])
    flag_cleared(at: 250)
    expect(ended("e1")).to eq(["fixed", 100, 250])
  end

  it "stands unfound until the flag is lowered, then reads fixed", :aggregate_failures do
    unfound("e1", at: 100)
    expect(ended("e1")).to eq(["unfound", 100, 0])
    flag_cleared(at: 250)
    expect(ended("e1")).to eq(["fixed", 100, 250])
  end

  it "ends fixed when the flag is lowered and the revert was refused" do
    reverting("e1", at: 100)
    flag_cleared(at: 400)
    expect(ended("e1")).to eq(["fixed", 100, 400])
  end

  it "leaves an ended episode as it ended when the flag is lowered again" do
    parked("e1", at: 100)
    [250, 900].each { |at| flag_cleared(at: at) }
    expect(ended("e1")).to eq(["fixed", 100, 250])
  end
end
