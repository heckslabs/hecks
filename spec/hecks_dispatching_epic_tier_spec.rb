require "spec_helper"
require_relative "support/roll_forward_fixtures"

# The order the dispatcher works in follows the item's own priority first, then its epic's tier
# (lowest first) among items of one priority, and no more than the world's `epic_wip_limit` items of one epic started at once.
RSpec.describe "dispatch picks by priority, then by the epic with the lowest tier" do
  include RollForwardFixtures

  let(:plan_class) { Hecks::Adapters::Dispatching::Plan }
  let(:items_class) { Hecks::Adapters::Dispatching::WorkItems }

  def registry_of(works, ranks)
    rows = { "Work" => works, "Epic" => ranks.map { |epic, tier| double(epic: epic, tier: tier) } }
    registry = double(bluebook: double(aggregates: rows.keys.map { |name| double(hecks_name: name, value_objects: []) }))
    allow(registry).to receive(:repository) { |_domain, aggregate| double(all: rows.fetch(aggregate.hecks_name)) }
    registry
  end

  def planned_keys(works, ranks = {}) = items_class.new(registry_of(works, ranks)).planned.map(&:key)

  def plan_with(planned, started: [], limit: 2)
    plan_class.new(planned, started, cap: 9, load: 0.0, max_load: 9.0, frozen: [], epic_wip: limit)
  end

  def plan_item(key, epic) = plan_class::Item.new(key: key, title: key, detail: "", area: [key], epic: epic)

  it "chooses the now item of tier 5 before the unprioritised item of tier 1" do
    works = [entry("early", epic: "e1"), entry("late", epic: "e5", priority: "now")]

    expect(planned_keys(works, "e1" => 1, "e5" => 5)).to eq(%w[late early])
  end

  it "chooses a now item in tier 7 before a later item in tier 1" do
    works = [entry("slow", epic: "e1", priority: "later"), entry("urgent", epic: "e7", priority: "now")]

    expect(planned_keys(works, "e1" => 1, "e7" => 7)).to eq(%w[urgent slow])
  end

  it "chooses a now item with no epic before a later item in tier 1" do
    works = [entry("slow", epic: "e1", priority: "later"), entry("loose", priority: "now")]

    expect(planned_keys(works, "e1" => 1)).to eq(%w[loose slow])
  end

  it "orders two now items by their epics' tiers" do
    works = [entry("late", epic: "e5", priority: "now"), entry("early", epic: "e1", priority: "now")]

    expect(planned_keys(works, "e1" => 1, "e5" => 5)).to eq(%w[early late])
  end

  it "sorts an item with no epic after tier 9 of the same priority" do
    works = [entry("loose", priority: "now"), entry("ranked", epic: "e9", priority: "now")]

    expect(planned_keys(works, "e9" => 9)).to eq(%w[ranked loose])
  end

  it "sorts an item whose epic is unranked or unknown after tier 9" do
    works = [entry("ghost", epic: "gone"), entry("ranked", epic: "e9")]

    expect(planned_keys(works, "e9" => 9)).to eq(%w[ranked ghost])
  end

  it "keeps a red item before the tier" do
    works = [entry("early", epic: "e1"), entry("red-x")]

    expect(planned_keys(works, "e1" => 1)).to eq(%w[red-x early])
  end

  it "holds the third item of an epic that has 2 started, and names it", :aggregate_failures do
    plan = plan_with([plan_item("c", "e1")], started: [plan_item("a", "e1"), plan_item("b", "e1")])

    expect(plan.chosen).to be_empty
    expect(plan.skipped.map(&:reason)).to eq(["skipped: held: epic e1 already has 2 started"])
  end

  it "counts the items chosen by the same fill", :aggregate_failures do
    plan = plan_with([plan_item("a", "e1"), plan_item("b", "e1"), plan_item("c", "e1")])

    expect(plan.chosen.map(&:key)).to eq(%w[a b])
    expect(plan.skipped.map(&:key)).to eq(%w[c])
  end

  it "does not hold an item of another epic" do
    plan = plan_with([plan_item("c", "e2")], started: [plan_item("a", "e1"), plan_item("b", "e1")])

    expect(plan.chosen.map(&:key)).to eq(%w[c])
  end

  it "does not hold an item with no epic" do
    expect(plan_with([plan_item("a", ""), plan_item("b", ""), plan_item("c", "")]).chosen.size).to eq(3)
  end
end
