# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_stages"
require_relative "support/board_rows"
require_relative "support/board_state_fixture"

# The rows the board's builders answer for the queries that are not on the strip, each built as
# the value object the bluebook declares for it: a cycle, a stage's statistics, a health check
# and an integration run.
RSpec.describe Hecks::Adapters::PipelineBoard::TypedRows do
  include BoardRows

  let(:cycle) { { work: "w", started: BoardStateFixture::AT, seconds: 160, open: "review", stages: spans } }
  let(:spans) { [{ stage: "queue", seconds: 120 }, { stage: "review", seconds: 40, open: true }] }

  it "says a cycle's stages in order, as words" do
    expect(built("Cycle", described_class.cycles([cycle]).first)).to include(work: "w", stages: "queue 120s, review 40s (open)")
  end

  it "gives a stage's median as a Reading, unknown when no item closed it" do
    stats = [{ stage: "queue", items: 0, median: nil, percentile: nil }]
    row = described_class.cycle_stats({ stats: stats, rank: 90 }, BoardStateFixture::AT).first
    expect(built("Reading", row)).to include(key: "cycle_queue", state: "unknown", note: "p90 -s over 0 items")
  end

  it "counts what a health check found, and says why when it could not be read", :aggregate_failures do
    rows = described_class.health({ boarded_by_hand: [{ key: "abc1234", minutes: 5 }] }, BoardStateFixture::AT)
    expect(built("Reading", rows.first)).to include(key: "boarded_by_hand", value: "1", state: "attention", note: "abc1234 5m")
    expect(built("Reading", rows.last)).to include(state: "unknown", note: "unknown: nothing read")
  end

  it "marks an integration run parked for a person" do
    run = { landed: "abc", stage: "needs_human", at: nil, minutes: nil, parked: true }
    expect(built("IntegrationRun", described_class.integration([run]).first)).to include(stage: "needs_human", parked: "yes")
  end
end
