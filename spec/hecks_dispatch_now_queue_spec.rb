require "spec_helper"
require "hecks/hecks/adapters/rolling"
require "hecks/pipeline_board/adapters/pipeline_stages/plan_order"

# The now lane is an ordered queue: Dispatch takes priority-now work strictly by step, and the
# epic's tier only breaks a tie of equal step. A now item nobody ordered waits at the end.
RSpec.describe "the now lane as an ordered queue" do
  Plan = Struct.new(:work, :title, :status, :priority, :step, :area, :detail, :yield_kind, :retry_at,
                    :yield_count, :epic, :waits_on, keyword_init: true)
  Tier = Struct.new(:epic, :tier)

  def now_item(key, epic, step)
    Plan.new(work: key, title: key, status: "planned", priority: "now", step: step, area: [], detail: "", epic: epic)
  end

  def planned_keys(items)
    records = { "Work" => items, "Epic" => [Tier.new("high", 1), Tier.new("low", 5)] }
    aggregates = %w[Work Epic].map { |name| double(hecks_name: name, value_objects: []) }
    registry = double(bluebook: double(aggregates: aggregates), world: double(for_verb: {}))
    allow(registry).to receive(:repository) { |_domain, aggregate| double(all: records.fetch(aggregate.hecks_name)) }
    Hecks::Adapters::Dispatching::WorkItems.new(registry).planned.map(&:key)
  end

  it "starts a now item of a later epic tier first when its step is lower" do
    expect(planned_keys([now_item("high-two", "high", 2), now_item("low-one", "low", 1)])).to eq(%w[low-one high-two])
  end

  it "breaks a tie of equal step by the epic's tier" do
    expect(planned_keys([now_item("low-one", "low", 1), now_item("high-one", "high", 1)])).to eq(%w[high-one low-one])
  end

  it "leaves a now item nobody ordered after the ordered ones" do
    expect(planned_keys([now_item("fresh", "high", nil), now_item("low-nine", "low", 9)])).to eq(%w[low-nine fresh])
  end

  it "lists the now lane on the board by step, an unordered item last", :aggregate_failures do
    rows = [{ lane: "now", step: "", slug: "fresh" }, { lane: "now", step: "2", slug: "b" },
            { lane: "now", step: "1", slug: "a" }, { lane: "now", step: nil, slug: "z" }]
    board = Hecks::Adapters::PipelineBoard::PlanOrder
    expect(board.items(rows).map { |row| row[:slug] }).to eq(%w[a b fresh z])
  end
end
