# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_stages"
require_relative "support/board_rows"
require_relative "support/glance_facts"

# The `Glance`: what stands too long, a train, epics and planned work.
# The `StuckKind` and `Verdict` rows decide it; the adapter only reshapes the facts.
RSpec.describe Hecks::Adapters::PipelineBoard::GlanceRows, ".build" do
  include BoardRows
  include GlanceFacts

  it "lists a train pull request left past its mark" do
    expect(kinds(train_prs: [pull(created: ago(3 * 3600))])).to eq(["train_blocked"])
  end

  it "leaves out a train pull request still within its mark" do
    expect(kinds(train_prs: [pull(created: ago(600))])).to be_empty
  end

  it "lists an epic past its hold, waiting on the product owner" do
    expect(entry(epics: [epic(ranked: GlanceFacts::NOW - (20 * 86_400))], kind: "epic_held"))
      .to include(group: "standing too long", waits_on: "product owner", waits_on_kind: "role")
  end

  it "leaves out an epic still held, and one the owner never ranked" do
    expect(kinds(epics: [epic(ranked: GlanceFacts::NOW - 86_400), epic(ranked: 0)])).to be_empty
  end

  it "lists planned work the fill would start but has not, past its mark" do
    expect(kinds(fill: { would_start: [{ slug: "w" }], headroom: 2, age_minutes: 45 })).to eq(["planned_idle"])
  end
end
