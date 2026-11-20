require "spec_helper"
require_relative "support/pipeline_board_world"
require "hecks/hecks/adapters/fill_watching"

# The fill's watch names the dominant reason, the reading, how long it has held and what governs
# it; the board states a standing stall as the first words of its headline.
RSpec.describe "a stalled fill's reading" do
  let(:plan) { Hecks::Adapters::Dispatching::Plan }
  let(:stall) { Hecks::Adapters::Dispatching::FillStall }
  let(:paused) { Array.new(3) { |index| plan::Skip.new("w#{index}", plan::LOAD_PAUSE) } }

  it "names the dominant reason of the waiting work" do
    expect(stall.dominant(paused + [plan::Skip.new("x", "skipped: cap 7 reached")])).to start_with("paused by load")
  end

  it "names the setting that governs a pause by load" do
    expect(stall.governor(paused)).to include("dispatch_max_load")
  end

  it "states the stall first in the board's headline" do
    fill = { cap: 7, load: 22.8, limit: 22.0, would_start: [], skipped: [], stalled: "41 minutes, held by x" }

    expect(Hecks::Adapters::PipelineBoard::Headline.sentence([], fill)).to start_with("FILL STALLED for 41 minutes")
  end

  it "says nothing while the fill flows" do
    fill = { cap: 7, load: 3.0, limit: 22.0, would_start: [], skipped: [], stalled: nil }

    expect(Hecks::Adapters::PipelineBoard::Headline.sentence([], fill)).not_to include("STALLED")
  end
end
