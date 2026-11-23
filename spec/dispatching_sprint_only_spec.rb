require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# The fill starts a work item only when it is in the open sprint or is a bug; a red-* fix starts
# too. Of the bugs, one takes a seat while a sprint item is ready.
RSpec.describe "a fill that starts only sprint work and bugs" do
  let(:plan_class) { Hecks::Adapters::Dispatching::Plan }

  let(:work)      { item("in-sprint", sprint: "2026-11-23") }
  let(:first_bug) { item("bug-one", category: "bug") }
  let(:next_bug)  { item("bug-two", category: "bug") }
  let(:other)     { item("off-sprint") }

  def item(key, sprint: "", category: "", priority: "now")
    plan_class::Item.new(key: key, title: key, detail: "", area: [key], priority: priority,
                         sprint: sprint, category: category)
  end

  def fill(planned, cap: 3)
    plan_class.new(planned, [], cap: cap, load: 1.0, max_load: 20.0, frozen: [], urgent_reserve: 0, sprint: true)
  end

  it "starts the sprint item and one bug", :aggregate_failures do
    plan = fill([work, first_bug, next_bug, other])
    expect(plan.chosen.map(&:key)).to eq(%w[in-sprint bug-one])
    expect(plan.skipped.find { |skip| skip.key == "off-sprint" }.reason).to eq("skipped: not in the open sprint")
  end

  it "holds the second bug while a sprint item is ready, even one later in plan order", :aggregate_failures do
    plan = fill([first_bug, next_bug, work])
    expect(plan.chosen.map(&:key)).to eq(%w[bug-one in-sprint])
    expect(plan.skipped.map(&:reason)).to eq(["skipped: held: bug bug-one already holds the one bug seat"])
  end

  it "starts a second bug when no sprint item is ready" do
    expect(fill([first_bug, next_bug, other]).chosen.map(&:key)).to eq(%w[bug-one bug-two])
  end

  it "starts only bugs with no open sprint" do
    expect(fill([other, first_bug]).chosen.map(&:key)).to eq(["bug-one"])
  end

  it "refuses an expedited item outside the sprint and starts a red-* fix" do
    plan = fill([item("hot", priority: "expedite"), item("red-main")])
    expect(plan.chosen.map(&:key)).to eq(["red-main"])
  end
end
