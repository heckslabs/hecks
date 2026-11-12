# frozen_string_literal: true

require "spec_helper"
require_relative "support/fake_journal"

require "hecks/pipeline_board/adapters/pipeline_web"

# The planning page: epics first, then areas inside an epic, every undone item once, the strip that
# answers what runs, what is next, what lands and what needs the owner, and the review note an item
# carries once it has been reviewed.
RSpec.describe Hecks::Adapters::PipelineBoard::PlanHtml do
  def item(slug, **fields)
    { slug: slug, title: "Title of #{slug}", status: "planned", area: [], priority: "", category: "", epic: "",
      claimed_by: "", claimed_at: "", budget_minutes: nil, yield_count: 0, reason: "", step: 1 }.merge(fields)
  end

  def reading(items: [], epics: [], sessions: [], reviews: [], fill: { would_start: [], skipped: [] })
    Hecks::Adapters::PipelineBoard::PlanReading.build(
      items: items, epics: epics, sessions: sessions, reviews: reviews, fill: fill,
      train: { name: "Train", state: "ok", count: "0", detail: "idle" }, now: Time.utc(2026, 11, 11, 12)
    )
  end

  def drawn(**kept) = described_class.draw(reading(**kept))

  let(:epic) do
    { epic: "hands-off", title: "Hands-off train", outcome: "A landing needs no hand", tier: "", done: 3,
      dropped: 1 }
  end

  it "puts an item under its epic with the epic's progress" do
    html = drawn(items: [item("a", epic: "hands-off", area: ["lib/x"])], epics: [epic])
    expect(html).to include("Hands-off train", "A landing needs no hand", "3 done", "1 dropped", "1 open", "Title of a")
  end

  it "lists an item with no epic under 'no epic' with the count, grouped by area" do
    html = drawn(items: [item("a", area: ["lib/x"]), item("b")])
    expect(html).to include("no epic (2)", "lib/x", "no area (1)")
  end

  it "names no area or category as an epic" do
    html = drawn(items: [item("a", category: "pipeline-board", area: ["lib/x"])])
    expect(html.scan('class="epic"').size).to eq(0)
  end

  it "shows a started item with its session, linked, and how long it has run" do
    session = { id: "s-1", status: "busy", work_item: "a", started: "2026-11-11T10:30:00Z" }
    html = drawn(items: [item("a", status: "started", claimed_by: "s-1")], sessions: [session])
    expect(html).to include('href="/runs/s-1"', "90 min")
  end

  it "lists an item with no priority as unset" do
    expect(drawn(items: [item("a")])).to include('data-priority="unset"')
  end

  it "says the owner's queue is empty" do
    expect(drawn(items: [item("a")])).to include("Needs you: nothing")
  end

  it "never says 'waiting on you' while the owner's queue is empty" do
    expect(drawn(items: [item("a")])).not_to include("waiting on you")
  end

  it "says 'waiting on you' when the owner has a blocked session" do
    session = { id: "s-2", status: "blocked", owner: true, work_item: "a" }
    expect(drawn(items: [item("a")], sessions: [session])).to include("waiting on you")
  end

  it "shows what the fill would start next and why another item is held" do
    fill = { would_start: [{ slug: "a" }], skipped: [{ slug: "b", reason: "area held by c" }] }
    expect(drawn(items: [item("a"), item("b")], fill: fill)).to include("Up next", "area held by c")
  end

  it "shows a yielded item's reason and yield count" do
    html = drawn(items: [item("a", yield_count: 2, reason: "load too high")])
    expect(html).to include("yielded 2", "load too high")
  end

  context "with plan reviews" do
    let(:reviews) do
      [{ work: "a", run: "r1", verdict: "rethink", findings: "old findings" },
       { work: "a", run: "r2", verdict: "changes", findings: "latest findings" }]
    end

    it "notes how many times an item was reviewed and its latest verdict once" do
      html = drawn(items: [item("a")], reviews: reviews)
      expect(html.scan("reviewed 2 times, latest verdict sound with changes").size).to eq(1)
    end

    it "keeps the latest findings behind a click and the older ones behind a second" do
      html = drawn(items: [item("a")], reviews: reviews)
      expect(html).to include("latest findings", "Earlier reviews", "old findings")
    end

    it "shows no note for an item never reviewed" do
      expect(drawn(items: [item("b")], reviews: reviews)).not_to include("reviewed")
    end
  end
end
