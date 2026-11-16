# frozen_string_literal: true

require "spec_helper"
require_relative "support/fake_journal"

require "hecks/pipeline_board/adapters/pipeline_web"

# The planning page's "Up next" card names a few queued items and counts the rest, and prints each hold
# reason once with a count, so a long queue is never a wall of text.
RSpec.describe Hecks::Adapters::PipelineBoard::PlanHtml do
  def item(slug)
    { slug: slug, title: "Title of #{slug}", status: "planned", area: [], priority: "", category: "", epic: "",
      claimed_by: "", claimed_at: "", budget_minutes: nil, yield_count: 0, reason: "", step: 1 }
  end

  def card_for(skipped:, would_start: [])
    reading = Hecks::Adapters::PipelineBoard::PlanReading.build(
      items: [item("a")], epics: [], sessions: [], reviews: [],
      fill: { would_start: would_start, skipped: skipped },
      train: { name: "Train", state: "ok", count: "0", detail: "idle" }, now: Time.utc(2026, 11, 11, 12)
    )
    described_class.draw(reading)[%r{<h3>Up next.*?</ul>}m]
  end

  let(:many) { (1..40).map { |n| { slug: "item-#{n}", reason: "cap 2 reached (3 started)" } } }

  it "prints one line per hold reason with a count" do
    card = card_for(skipped: many)
    expect(card.scan("cap 2 reached").size).to eq(1)
  end

  it "counts the held items on that line" do
    expect(card_for(skipped: many)).to include("40 held")
  end

  it "names at most three queued items and counts the rest" do
    queued = (1..9).map { |n| { slug: "queued-#{n}" } }
    card = card_for(skipped: [], would_start: queued)
    expect(card).to include("and 6 more")
  end

  it "does not list the held items one by one" do
    expect(card_for(skipped: many)).not_to include("item-40")
  end
end
