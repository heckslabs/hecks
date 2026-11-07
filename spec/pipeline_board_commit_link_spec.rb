# frozen_string_literal: true

require "spec_helper"
require_relative "support/pipeline_board_world"
require "hecks/pipeline_board/adapters/pipeline_web"

# A landed commit as the run page links it.
RSpec.describe Hecks::Adapters::PipelineBoard::CommitLink do
  it "links the commit and the CI run on its short sha" do
    link = described_class.of("a" * 40, "https://github.com/o/r", [{ sha: "a" * 7, url: "https://ci/1" }])
    expect(link).to eq(sha: "a" * 9, url: "https://github.com/o/r/commit/#{"a" * 40}", ci_url: "https://ci/1")
  end

  it "leaves the links nil where they are unknown" do
    expect(described_class.of("a" * 40, { unknown: "x" }, { unknown: "y" })).to include(url: nil, ci_url: nil)
  end
end
