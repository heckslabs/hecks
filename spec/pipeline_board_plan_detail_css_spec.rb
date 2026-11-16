# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_web"

# The planning page's opened Work item detail and its plan review are bounded, readable blocks, not
# full-width monospace walls.
RSpec.describe "the planning page's text blocks" do
  describe "the detail block" do
    let(:page) { File.expand_path("../lib/hecks/pipeline_board/adapters/pipeline_web/plan.html", __dir__) }
    let(:rule) { File.read(page)[/^#plan \.item \.detail pre \{(.*?)\}/m, 1] }

    it "is found in the page" do
      expect(rule).not_to be_nil
    end

    it "bounds the width and the height, and scrolls inside its box", :aggregate_failures do
      expect(rule).to match(/max-width:\s*72ch/)
      expect(rule).to match(/max-height:\s*16em/)
      expect(rule).to match(/overflow:\s*auto/)
    end

    it "reads as proportional prose and keeps its line breaks", :aggregate_failures do
      expect(rule).to include("var(--body)")
      expect(rule).not_to include("var(--mono)")
      expect(rule).to include("white-space: pre-wrap")
    end
  end

  describe "the review block" do
    let(:page_path) { File.expand_path("../lib/hecks/pipeline_board/adapters/pipeline_web/plan.html", __dir__) }
    let(:rule) { File.read(page_path)[/^\.review pre \{(.*?)\}/m, 1] }
    let(:findings) { "**Verdict:** sound.\n\n## Blocking\n\n#{"- **Plan:** a long finding. " * 220}" }

    def drawn_with_review(text)
      reading = Hecks::Adapters::PipelineBoard::PlanReading.build(
        items: [{ slug: "a", title: "T", status: "planned", area: [], priority: "", category: "", epic: "",
                  claimed_by: "", claimed_at: "", budget_minutes: nil, yield_count: 0, reason: "", step: 1 }],
        epics: [], sessions: [], fill: { would_start: [], skipped: [] },
        reviews: [{ work: "a", run: "r1", verdict: "changes", findings: text }],
        train: { name: "Train", state: "ok", count: "0", detail: "idle" }, now: Time.utc(2026, 11, 11, 12)
      )
      Hecks::Adapters::PipelineBoard::PlanHtml.draw(reading)
    end

    it "is found in the page" do
      expect(rule).not_to be_nil
    end

    it "bounds the width and the height, and scrolls inside its box", :aggregate_failures do
      expect(rule).to match(/max-width:\s*72ch/)
      expect(rule).to match(/max-height:\s*22em/)
      expect(rule).to match(/overflow:\s*auto/)
    end

    it "reads as proportional prose and keeps its line breaks", :aggregate_failures do
      expect(rule).to include("var(--body)")
      expect(rule).not_to include("var(--mono)")
      expect(rule).to include("white-space: pre-wrap")
    end

    it "matches the markup a long review is drawn into", :aggregate_failures do
      html = drawn_with_review(findings)
      expect(html).to include('<details class="review"><summary>reviewed 1 time, latest verdict')
      expect(html).to match(%r{<details class="review"><summary>[^<]*</summary><pre>\*\*Verdict:\*\*})
    end
  end
end
