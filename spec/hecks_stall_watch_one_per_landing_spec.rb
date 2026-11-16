require "spec_helper"
require "json"
require "tmpdir"
require "hecks/hecks/adapters/stall_watching"

# Tap lines and the landing-carry row for the one-stall-per-landing group.
module OnePerLandingLooks
  NOW = Time.utc(2026, 11, 16, 12, 0, 0)
  KIND = { kind: "landing-carry", not_about: "stall-", aggregate: "Delivery::Landing", opens: "CarryRequested",
           closes: "BranchLanded,LandingRefused", minutes: 30, forgets: 1440, fixer: "orchestrator", move: "look" }.freeze

  def carry(run, minutes_ago, branch = "work-a", event = "CarryRequested")
    { "kind" => "event", "at" => (NOW - (minutes_ago * 60)).iso8601, "aggregate" => "Delivery::Landing", "id" => run,
      "event" => event, "links" => { "branch" => branch } }
  end

  def filed(run) = { "kind" => "event", "event" => "StallFiled", "id" => "stall-landing-carry-#{run}" }

  def subjects(lines)
    Hecks::Adapters::StallWatching::Sightings.new([KIND], NOW.to_i).rows(lines, "look").map { |row| row[:subject] }
  end
end

# A landing is one branch: the landing-carry kind files one stall for it however many carry runs
# the branch has.
RSpec.describe Hecks::Adapters::StallWatching::Sightings do
  include OnePerLandingLooks

  it "files the latest carry of a branch only" do
    expect(subjects([carry("old", 90), carry("new", 40)])).to eq(["new"])
  end

  it "files nothing more for a branch whose older carry is filed" do
    expect(subjects([carry("old", 90), filed("old"), carry("new", 40)])).to eq([])
  end

  it "files a carry again once the filed one has landed" do
    lines = [carry("old", 90), filed("old"), carry("old", 80, "work-a", "BranchLanded"), carry("new", 40)]

    expect(subjects(lines)).to eq(["new"])
  end

  it "files each branch's own carry" do
    expect(subjects([carry("a", 40), carry("b", 40, "work-b")])).to contain_exactly("a", "b")
  end
end
