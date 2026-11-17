# frozen_string_literal: true

require "spec_helper"
require_relative "support/fake_journal"

require "hecks/pipeline_board/adapters/pipeline_web"

# The planning page draws every lane (now, next, later, and the items in no epic) as a panel shut
# like the home page's: a heading, its counts and the first epics by name; a click opens it, the
# choice is kept, and a filter opens the lanes it found something in.
RSpec.describe Hecks::Adapters::PipelineBoard::PlanHtml do
  def item(slug, epic: "", priority: "next")
    { slug: slug, title: "Title of #{slug}", status: "planned", area: [], priority: priority, category: "", epic: epic,
      claimed_by: "", claimed_at: "", budget_minutes: nil, yield_count: 0, reason: "", step: 1 }
  end

  def epic(slug)
    { epic: slug, title: "Epic #{slug}", outcome: "o", tier: "", done: 2, dropped: 0 }
  end

  def drawn(items:, epics: [])
    described_class.draw(
      Hecks::Adapters::PipelineBoard::PlanReading.build(
        items: items, epics: epics, sessions: [], reviews: [], fill: { would_start: [], skipped: [] },
        train: { name: "Train", state: "ok", count: "0", detail: "idle" }, now: Time.utc(2026, 11, 11, 12)
      )
    )
  end

  let(:page) { File.read(File.expand_path("../lib/hecks/pipeline_board/adapters/pipeline_web/plan.html", __dir__)) }
  let(:epics) { (1..6).map { |n| epic("e#{n}") } }
  let(:items) { (1..6).map { |n| item("i#{n}", epic: "e#{n}") } }

  it "draws a lane as a panel with no open attribute, so it is shut" do
    expect(drawn(items: items, epics: epics)).to include('<details class="lane" data-lane="next"><summary>')
  end

  it "names the first three epics in the header and counts the rest" do
    expect(drawn(items: items, epics: epics)).to include("Epic e1, Epic e2, Epic e3 and 3 more")
  end

  it "counts the finished items in the header" do
    expect(drawn(items: items, epics: epics)).to include('<span class="ok"><b>12</b> done</span>')
  end

  it "draws the items in no epic as a shut lane of their own" do
    html = drawn(items: [item("a", priority: "later"), item("b", priority: "later")])
    expect(html).to match(%r{<details class="lane" data-lane="none"><summary><h2>No epic</h2>.*Title of a, Title of b}m)
  end

  it "shuts a lane unless the owner opened it or a filter found something in it" do
    expect(page).to include("lane.open = filtering ? !lane.hidden : Boolean(laneOpen[lane.dataset.lane])")
  end

  it "keeps the lanes the owner opened across visits" do
    expect(page).to include('localStorage.setItem("plan-lanes"')
  end

  it "does not print the drag hint" do
    expect(page).not_to include("Drag an item or an epic")
  end
end
