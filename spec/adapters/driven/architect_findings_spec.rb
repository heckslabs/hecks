# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/architect_findings"

# What a plan review keeps of the architect's closing message: its head and its tail.
RSpec.describe Hecks::Adapters::ArchitectFindings do
  def long_review = "Verdict reason first.\n#{"x" * 70_000}\nVerdict: sound"

  def findings_of(size) = "Findings.\n#{"x" * size}\nVerdict: changes"

  it "delivers a review past the old 4000-character cap whole" do
    expect(described_class.clip(findings_of(12_000))).to eq(findings_of(12_000))
  end

  it "keeps an oversize review's first line and its Verdict line", :aggregate_failures do
    kept = described_class.clip(long_review)
    expect(kept).to start_with("Verdict reason first.\n")
    expect(kept).to end_with("\nVerdict: sound")
  end

  it "says how much it kept of how much, never cutting silently" do
    expect(described_class.clip(long_review)).to include("findings cut at 60000 of #{long_review.length} characters")
  end

  it "keeps a text within the limit whole" do
    expect(described_class.clip("Five findings.\nVerdict: sound")).to eq("Five findings.\nVerdict: sound")
  end

  it "prefers the transcript's whole closing message to the job's tail" do
    expect(described_class.pick("Whole message.", "ole message.")).to eq("Whole message.")
  end

  it "falls back to the job's text when the transcript holds none" do
    expect(described_class.pick("", "ole message.")).to eq("ole message.")
  end
end
