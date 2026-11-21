# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_stages"
require_relative "support/board_rows"
require_relative "support/glance_facts"

# The `Glance`: what stands too long, a red main, a session, a stopped run.
# The `StuckKind` and `Verdict` rows decide it; the adapter only reshapes the facts.
RSpec.describe Hecks::Adapters::PipelineBoard::GlanceRows, ".build" do
  include BoardRows
  include GlanceFacts

  it "lists a red main that has stood past its mark, waiting on a role" do
    expect(entry(red_episodes: [episode("requested", began: GlanceFacts::NOW - 7200)], kind: "red_main"))
      .to include(group: "standing too long", waits_on: "orchestrator", waits_on_kind: "role")
  end

  it "leaves out a red main still within its mark" do
    expect(kinds(red_episodes: [episode("requested", began: GlanceFacts::NOW - 60)])).to be_empty
  end

  it "lists a busy session with no word past its mark" do
    expect(kinds(sessions: [GlanceFacts::STALLED])).to eq(["stalled_session"])
  end

  it "lists a stopped run nobody picked up past its hours" do
    expect(kinds(stopped_runs: [GlanceFacts::STOP], stopped_times: { "abcdefghij" => ago(5 * 3600) })).to eq(["stopped_run"])
  end

  it "leaves out a stopped run under its hours" do
    expect(kinds(stopped_runs: [GlanceFacts::STOP], stopped_times: { "abcdefghij" => ago(3600) })).to be_empty
  end
end
