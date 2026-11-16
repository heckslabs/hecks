# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_web"

# The one-line summary of a Work item's detail on the planning page.
RSpec.describe Hecks::Adapters::PipelineBoard::PlanDetail, ".summary" do
  it "cuts a 3000-character detail to at most 140 characters" do
    expect(described_class.summary("Observed facts. #{"More text. " * 270}#{"x" * 200}").length).to be <= 140
  end

  it "takes the first sentence when it is short" do
    expect(described_class.summary("Plan is wrong. It fails twice.")).to eq("Plan is wrong.")
  end

  it "takes a text with no full stop whole, cut at the limit", :aggregate_failures do
    expect(described_class.summary("no stop")).to eq("no stop")
    expect(described_class.summary("x" * 300)).to end_with("…")
  end

  it "cuts a long first sentence to exactly the limit" do
    expect(described_class.summary("#{"word " * 100}end.").length).to be <= described_class::LIMIT
  end
end
