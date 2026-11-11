require "spec_helper"
require_relative "support/roll_forward_fixtures"

# A roll starts only the work the owner marked by giving it a priority, plus the red items; the
# items nobody marked wait for a manual fill.
RSpec.describe "which planned work a roll may start" do
  include RollForwardFixtures

  it "leaves out an item nobody gave a priority" do
    expect(rollable(["plain"], ["marked", { priority: "later" }])).to eq(%w[marked])
  end

  it "keeps a red item whether or not anyone marked it" do
    expect(rollable(["red-main"], ["plain"], ["a", { priority: "now" }])).to eq(%w[red-main a])
  end

  it "keeps the marked items in priority order", :aggregate_failures do
    expect(rollable(["l", { priority: "later" }], ["n", { priority: "now" }], ["x"])).to eq(%w[n l])
    expect(ordered(["x"], ["n", { priority: "now" }])).to eq(%w[n x])
  end

  it "skips an overlapping marked item by name and starts the next", :aggregate_failures do
    marked = [["a", %w[core]], ["b", %w[core]], ["c", %w[edge]]]
    plan = plan_of(marked)

    expect(plan.chosen.map(&:key)).to eq(%w[a c])
    expect(plan.skipped.map(&:key)).to eq(%w[b])
  end
end
