# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_stages"
require_relative "support/board_rows"
require_relative "support/status_facts"

# The first line of `Now`: the `Idle reason` verdict and the `IdleReason` rows word it; the
# adapter only counts what the fill and admission readers answered.
RSpec.describe Hecks::Adapters::PipelineBoard::PipelineStatus, ".build (why idle)" do
  include BoardRows
  include StatusFacts

  def described_class = Hecks::Adapters::PipelineBoard::PipelineStatus

  it "says why nothing starts while an overload holds admission" do
    row = status(overloads: [{ reason: "load 31 over 20" }], fill: fill)
    expect(row).to include(why_idle: /min: w held by load 31 over 20/, why_source: "overloads and load guard")
  end

  it "names the setting that governs the hold" do
    expect(status(overloads: [{ reason: "x" }], fill: fill)[:governed_by]).to include("Admission rows")
  end

  it "names the fill's skip reasons when every item is skipped" do
    held = { would_start: [], skipped: [{ slug: "a", reason: "area busy" }], at: ago(60) }
    expect(status(overloads: [], fill: held)).to include(why_idle: /a: area busy/, why_source: /fill report at/)
  end

  it "is silent while the fill would start work" do
    expect(status(overloads: [], fill: fill)).to include(why_idle: "", governed_by: "")
  end

  it "says the fill was not read when it was not" do
    expect(status(overloads: [], fill: { unknown: "none" })[:why_idle]).to include("fill was not read")
  end
end
