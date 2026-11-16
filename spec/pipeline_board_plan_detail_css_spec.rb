# frozen_string_literal: true

require "spec_helper"

# An opened Work item detail is a bounded, readable block, not a full-width monospace wall.
RSpec.describe "the planning page's detail block" do
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
