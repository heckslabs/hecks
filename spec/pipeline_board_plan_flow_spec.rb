# frozen_string_literal: true

require "spec_helper"

require "hecks/pipeline_board/adapters/pipeline_web"

# How the plan moves, on the planning page: the Work items planned, finished and dropped on each of
# the last days, the rate of each, and whether the plan grows or shrinks at that pace.
RSpec.describe Hecks::Adapters::PipelineBoard::PlanFlow do
  let(:now) { Time.new(2026, 11, 14, 9, 0, 0, "-07:00") }
  let(:yesterday) { "2026-11-13T20:00:00Z" }

  def flow(planned: [], finished: [], dropped: [], open: 30)
    described_class.build({ planned: planned, finished: finished, dropped: dropped }, now, open)
  end

  def drawn(**kept) = Hecks::Adapters::PipelineBoard::PlanFlowHtml.draw(flow(**kept))

  it "counts what was planned, finished and dropped on each day", :aggregate_failures do
    day = flow(planned: [yesterday] * 3, finished: [yesterday], dropped: [yesterday] * 2)[:days][-2]
    expect(day.values_at(:day, :planned, :finished, :dropped)).to eq(["2026-11-13", 3, 1, 2])
  end

  it "rates each over the days before today, since today is still open" do
    expect(flow(planned: [yesterday] * 26, finished: ["2026-11-14T16:00:00Z"] * 9)[:rates])
      .to eq({ planned: 2.0, finished: 0.0, dropped: 0.0 })
  end

  it "says the plan grows when more is planned than closed", :aggregate_failures do
    growing = flow(planned: [yesterday] * 26, finished: [yesterday] * 13)
    expect(growing.values_at(:net, :clears_in)).to eq([1.0, nil])
    expect(Hecks::Adapters::PipelineBoard::PlanFlowHtml.draw(growing)).to include("The plan grows by 1.0 items a day.")
  end

  it "says how long the open items take to clear when the plan shrinks", :aggregate_failures do
    shrinking = flow(planned: [yesterday] * 13, finished: [yesterday] * 26, dropped: [yesterday] * 13, open: 30)
    expect(shrinking.values_at(:net, :clears_in)).to eq([-2.0, 15])
    expect(Hecks::Adapters::PipelineBoard::PlanFlowHtml.draw(shrinking)).to include("30 open items clear in about 15 days")
  end

  it "draws a pair of bars for each day, today last" do
    html = drawn(planned: [yesterday])
    expect([html.scan('class="fday').size, html.scan('class="fday today"').size]).to eq([14, 1])
  end

  it "hands back events that were not read as they were, and draws nothing for them", :aggregate_failures do
    unread = described_class.build({ unknown: "no store" }, now, 3)
    expect(unread).to eq({ unknown: "no store" })
    expect(Hecks::Adapters::PipelineBoard::PlanFlowHtml.draw(unread)).to eq("")
  end
end
