# frozen_string_literal: true

require "spec_helper"
require_relative "support/fake_journal"

require "hecks/pipeline_board/adapters/pipeline_web"

# Running now on the planning page is one panel, drawn open, whose body holds every running item
# with its epic, its session and how long it has run; each item is drawn once, and the overview's
# card is a count that links to the panel.
RSpec.describe Hecks::Adapters::PipelineBoard::PlanHtml do
  def item(slug, **fields)
    { slug: slug, title: "Title of #{slug}", status: "planned", area: [], priority: "next", category: "", epic: "",
      claimed_by: "", claimed_at: "", budget_minutes: nil, yield_count: 0, reason: "", step: 1 }.merge(fields)
  end

  def session(work) = { id: "s-#{work}", status: "busy", work_item: work, started: "2026-11-11T11:15:00Z" }

  def reading(items, sessions)
    Hecks::Adapters::PipelineBoard::PlanReading.build(
      items: items, epics: [{ epic: "e1", title: "Epic one", outcome: "o", tier: "", done: 1, dropped: 0 }],
      sessions: sessions, reviews: [], fill: { would_start: [], skipped: [] },
      train: { name: "Train", state: "ok", count: "0", detail: "idle" }, now: Time.utc(2026, 11, 11, 12)
    )
  end

  # The HTML of the `<details>` element that opens at `start`, its nested `<details>` included.
  def element_at(html, start)
    depth = 0
    html.to_enum(:scan, %r{<details\b|</details>}).each do
      at = Regexp.last_match
      next if at.begin(0) < start

      depth += at[0] == "</details>" ? -1 : 1
      return html[start...at.end(0)] if depth.zero?
    end
  end

  def panel(html, lane) = element_at(html, html.index("<details class=\"lane\" data-lane=\"#{lane}\""))

  def drawn(items, sessions) = described_class.draw(reading(items, sessions))

  let(:items) { [item("a", epic: "e1", status: "started"), item("b", epic: "e1"), item("c", status: "started")] }
  let(:html) { drawn(items, [session("a"), session("c")]) }

  it "draws each running item's row inside the running lane's panel, with its epic, session and minutes",
     :aggregate_failures do
    running = panel(html, "running")
    expect(running).to include('data-slug="a"', 'data-slug="c"', "Epic one", "no epic")
    expect(running).to include('<a href="/runs/s-a">session</a> 45 min')
  end

  it "draws the panel open with its count of items" do
    expect(html).to include('<details class="lane" data-lane="running" id="running" data-drawn="open" open><summary>' \
                            '<h2>Running now</h2><span class="sum"><span class="counts">2 items running</span>')
  end

  it "draws the running panel before every other lane" do
    expect(html.index('data-lane="running"')).to be < html.index('data-lane="next"')
  end

  it "draws each running item once on the page" do
    expect([html.scan('data-slug="a"').size, html.scan('data-slug="c"').size]).to eq([1, 1])
  end

  it "keeps the rest of the epic under the lane of its other open items, its counts unchanged", :aggregate_failures do
    expect(panel(html, "next")).to include("Epic one", 'data-slug="b"', "1 of 3 done", "2 open items")
    expect(panel(html, "next")).not_to include('data-slug="a"')
  end

  it "makes the overview's card a count that links to the panel" do
    expect(html).to include('<h3>Running now (2)</h3><ul><li><a href="#running">2 items running</a></li></ul>')
  end

  it "says nothing is running when no session runs an item" do
    expect(panel(drawn([item("b", epic: "e1")], []), "running")).to include("nothing is running")
  end

  it "puts an epic whose open items all run under now" do
    expect(panel(drawn([item("a", epic: "e1", status: "started")], [session("a")]), "now")).to include("Epic one")
  end
end
