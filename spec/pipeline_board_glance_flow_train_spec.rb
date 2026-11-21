# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_stages"
require_relative "support/board_rows"
require_relative "support/glance_facts"

# The `Glance`: whether work flows, the fill and the train.
# The `StuckKind` and `Verdict` rows decide it; the adapter only reshapes the facts.
RSpec.describe Hecks::Adapters::PipelineBoard::GlanceRows, ".build" do
  include BoardRows
  include GlanceFacts

  it "names what the fill would start next" do
    fill = { would_start: [{ slug: "first", title: "First" }, { slug: "second", title: "Second" }] }
    expect(flowing(fill: fill)[:next_start].map { |item| item[:slug] }).to eq(%w[first second])
  end

  it "says the train failed and names the red pull request" do
    expect(flowing(train_prs: [pull(failed: 1, number: 9)])).to include(train_state: "failed", train_why: "#9 red")
  end

  it "says the train works while a pull request is pending, and is ok when all pass", :aggregate_failures do
    expect(flowing(train_prs: [pull(pending: 1)])[:train_state]).to eq("working")
    expect(flowing(train_prs: [pull])[:train_state]).to eq("ok")
  end

  it "says the train is idle with none open and unknown when unread", :aggregate_failures do
    expect(flowing(train_prs: [])[:train_state]).to eq("idle")
    expect(flowing({})[:train_state]).to eq("unknown")
  end
end
