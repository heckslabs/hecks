# frozen_string_literal: true

require "spec_helper"

# An architect's closing text that says nothing was checked is never read as sound.
RSpec.describe Hecks::Adapters::ArchitectVerdict do
  it "reads sound as sound" do
    expect(described_class.of("Verdict: sound")).to eq("sound")
  end

  it "reads a sound line as sound even when the report quotes the phrase nothing was checked" do
    expect(described_class.of("No file said Nothing was checked.\n\nVerdict: sound")).to eq("sound")
  end

  it "reads an unverified line as unverified" do
    expect(described_class.of("Verdict: unverified")).to eq("unverified")
  end
end
