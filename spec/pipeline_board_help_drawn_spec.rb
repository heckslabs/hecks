# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_stages"
require "hecks/pipeline_board/adapters/pipeline_web"

# Where the board draws the calls for help the owner is shown: the plan page's card, the text
# panel and the main page's waiting-on-you group.
RSpec.describe "HelpWanted lines where the board draws them" do
  let(:help) { [{ help: "help-stall-x", line: "needs you: login for X, 3h", minutes: 185 }] }
  let(:page) { File.read(File.expand_path("../lib/hecks/pipeline_board/adapters/pipeline_web/page.html", __dir__)) }
  let(:held) { { items: [], epics: [], sessions: [], reviews: [], fill: { would_start: [], skipped: [] }, train: nil } }

  def plan(help)
    reading = Hecks::Adapters::PipelineBoard::PlanReading.build(now: Time.utc(2026, 11, 20), help: help, **held)
    Hecks::Adapters::PipelineBoard::PlanHtml.draw(reading)
  end

  it "lists the line on the plan page's card and counts it" do
    expect(plan(help)).to include("1 waiting on you", "needs you: login for X, 3h")
  end

  it "says the owner's queue is empty when no call is shown" do
    expect(plan([])).to include("Needs you: nothing")
  end

  it "lists the line in the text panel under its own heading" do
    rows = Hecks::Adapters::PipelineBoard::Panel::Work.new({ sessions: [], waiting_on_you: { help: help } }, 5, 80).sessions
    expect(rows.map(&:first)).to eq(["needs you (1)", "  needs you: login for X, 3h"])
  end

  it "draws the lines in the main page's waiting-on-you group" do
    expect(page).to include("waiting_on_you.help")
  end

  it "sums the sessions and the lines once for the page's summary and leaves the sessions' count alone" do
    summed = '(sized["Sessions waiting on you"] || 0) + (sized["Help waiting on you"] || 0)'
    expect(page).to include(summed, "lastState.waiting_on_you.count")
  end
end
