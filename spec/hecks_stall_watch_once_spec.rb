require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/stall_watch_looks"

# A beat of the clock is a process of its own, so the Stall store starts empty each time and only
# the tap remembers: a stall is filed once, and one whose run has ended is abandoned once.
RSpec.describe "StallWatch over many beats" do
  include_context "with a stall watch tap"

  def filed_then_ended
    write_open_review
    beat("look-1")
    append_tap("SessionFinished", "lost", "Hecks::AgentRun")
  end

  it "files an open stall once over three beats" do
    write_open_review
    3.times { |look| beat("look-#{look}") }

    expect(events_named("StallFiled")).to eq(1)
  end

  it "lists no filed stall as unclosed again" do
    write_open_review
    append_tap("StallFiled", "stall-plan-review-lost", "Hecks::Stall")

    expect(watching.unclosed(run: "look-1")).to be_empty
  end

  it "never files a stall whose run has already ended" do
    write_open_review
    append_tap("SessionFinished", "lost", "Hecks::AgentRun")
    beat("look-1")

    expect(events_named("StallFiled")).to eq(0)
  end

  it "lists a filed stall whose run ended once as abandoned, naming the ending event", :aggregate_failures do
    filed_then_ended
    rows = watching.abandoned(run: "look-2")

    expect(rows.map { |row| row[:stall] }).to eq(%w[stall-plan-review-lost])
    expect(rows.first[:reason]).to include("SessionFinished")
  end

  it "abandons it once over three beats and drops its work item", :aggregate_failures do
    filed_then_ended
    3.times { |look| beat("again-#{look}") }

    expect(events_named("StallAbandoned")).to eq(1)
    expect(keys("Tickets", "Work", :status)).to eq(%w[dropped])
  end
end
