# frozen_string_literal: true

require "spec_helper"
require_relative "support/fake_journal"

require "hecks/pipeline_board/adapters/pipeline_web"

# An epic's row on the planning page names the decisions it carries out: its own, then the ones its items name,
# each once, as small tags after the epic's name.
RSpec.describe Hecks::Adapters::PipelineBoard::PlanHtml do
  def item(slug, epic: "e1", decision: "")
    { slug: slug, title: "Title of #{slug}", status: "planned", area: [], priority: "next", category: "", epic: epic,
      claimed_by: "", claimed_at: "", budget_minutes: nil, yield_count: 0, reason: "", step: 1, decision: decision }
  end

  def drawn(items:, epic_decision: "")
    epic = { epic: "e1", title: "Epic one", outcome: "o", tier: "", done: 0, dropped: 0, decision: epic_decision }
    described_class.draw(
      Hecks::Adapters::PipelineBoard::PlanReading.build(
        items: items, epics: [epic], sessions: [], reviews: [], fill: { would_start: [], skipped: [] },
        train: { name: "Train", state: "ok", count: "0", detail: "idle" }, now: Time.utc(2026, 11, 11, 12)
      )
    )
  end

  it "tags an epic with the decision its items name, once" do
    html = drawn(items: [item("a", decision: "0163"), item("b", decision: "0163")])
    expect(html.scan("ADR 0163").size).to eq(1)
  end

  it "tags an epic with its own decision first" do
    html = drawn(items: [item("a", decision: "0163")], epic_decision: "0042")
    expect(html).to include("ADR 0042 ADR 0163")
  end

  it "draws no tag for an epic that names no decision" do
    expect(drawn(items: [item("a")])).not_to include('class="adr"')
  end
end
