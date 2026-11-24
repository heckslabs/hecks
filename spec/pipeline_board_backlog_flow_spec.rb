# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_web"

# The backlog's inflow (items planned) against its outflow (items finished or dropped), by day.
RSpec.describe Hecks::Adapters::PipelineBoard::PlanFlow do
  let(:now) { Time.new(2026, 11, 14, 9, 0, 0, "-07:00") }
  let(:yesterday) { "2026-11-13T20:00:00Z" }

  def day(**times) = described_class.build({ planned: [], finished: [], dropped: [] }.merge(times), now, 10)[:days][-2]

  it "reads inflow 5 and outflow 3 for a day with 5 items added and 3 done" do
    expect(day(planned: [yesterday] * 5, finished: [yesterday] * 3)).to include(inflow: 5, outflow: 3)
  end

  it "counts an item dropped as leaving the backlog" do
    expect(day(planned: [yesterday], finished: [yesterday], dropped: [yesterday])).to include(inflow: 1, outflow: 2)
  end
end
