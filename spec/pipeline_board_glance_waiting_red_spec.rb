# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_stages"
require_relative "support/board_rows"
require_relative "support/glance_facts"

# The board's `Glance`, what waits on a person: a red main. The `StuckKind` and `Verdict` rows decide
# the members and how long is too long; the adapter only reshapes the facts it is handed.
RSpec.describe Hecks::Adapters::PipelineBoard::GlanceRows, ".build" do
  include BoardRows
  include GlanceFacts

  it "lists a red main whose episode parked, waiting on the owner" do
    expect(entry(red_episodes: [episode("parked")], kind: "red_main_given_up"))
      .to include(group: "waiting on a person", waits_on: "owner", waits_on_kind: "person")
  end

  it "lists a red main whose culprit was unfound" do
    expect(kinds(red_episodes: [episode("unfound")])).to eq(["red_main_given_up"])
  end

  it "leaves out a red main being reverted automatically, however long it has stood" do
    expect(kinds(red_episodes: [episode("reverting", began: GlanceFacts::NOW - 86_400)])).to be_empty
  end
end
