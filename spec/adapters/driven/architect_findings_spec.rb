# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/architect_findings"

# What a plan review keeps of the architect's closing message: its head and its tail.
RSpec.describe Hecks::Adapters::ArchitectFindings do
  def long_review = "Verdict reason first.\n#{"x" * 5000}\nVerdict: sound"

  it "keeps a 5000-character finding's first line and its last line", :aggregate_failures do
    kept = described_class.clip(long_review)
    expect(kept).to start_with("Verdict reason first.\n")
    expect(kept).to end_with("\nVerdict: sound")
  end

  it "names how much it left out between the head and the tail" do
    expect(described_class.clip(long_review)).to include("[… #{long_review.length - 4000} characters left out …]")
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
