require "spec_helper"
require_relative "support/red_episode_helpers"

# A red episode is the whole record of one stretch of red main: when it began, when it ended and
# how. Every time is passed in, since the bluebook reads no clock, and everything runs in Memory.
RSpec.describe "the queries over red episodes" do
  include_context "with red episodes in Memory"

  before do
    acquitted("old", at: 100)
    parked("mid", at: 200)
    reverting("new", at: 300)
  end

  it "lists the recent episodes newest first" do
    expect(mine(asked("Recent", limit: 50))).to eq(%w[new mid old])
  end

  it "lists no more episodes than the limit" do
    expect(mine(asked("Recent", limit: 2))).to eq(%w[new mid])
  end

  it "tells the standing episodes, newest first" do
    expect(mine(asked("Standing"))).to eq(%w[new mid])
  end

  it "tells no episode standing once the flag is lowered" do
    flag_cleared(at: 500)
    expect(asked("Standing")).to be_empty
  end
end
