require "spec_helper"
require_relative "support/roll_forward_fixtures"

# The order planned work is chosen in, by a manual filling and by the rolling policies alike: a red
# item, then `now`, `next`, `later`, none, then step.
RSpec.describe "the order planned work rolls forward in" do
  include RollForwardFixtures

  it "puts a planned red item before a now item" do
    expect(ordered(["a", { priority: "now" }], ["red-b"])).to eq(%w[red-b a])
  end

  it "orders now, next, later, then none" do
    expect(ordered(["n"], ["l", { priority: "later" }], ["x", { priority: "next" }], ["w", { priority: "now" }]))
      .to eq(%w[w x l n])
  end

  it "orders one priority by step, then by key" do
    now = { priority: "now" }
    expect(ordered(["b", now.merge(step: 2)], ["z", now.merge(step: 1)], ["a", now.merge(step: 2)])).to eq(%w[z a b])
  end

  it "skips an overlapping item and starts the next that does not overlap", :aggregate_failures do
    plan = plan_of([["first", %w[core]], ["second", %w[core]], ["third", %w[edge]]])

    expect(plan.chosen.map(&:key)).to eq(%w[first third])
    expect(plan.skipped.map(&:key)).to eq(%w[second])
  end
end
