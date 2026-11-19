require "spec_helper"
require_relative "support/coordinator_role_data"

# The sizes a brief's budget is named from: each says why, a lookup starts no subagents, no size
# starts more than the three the bounded-fan-out rule allows, and the role files name every size.
RSpec.describe "the Role aggregate's EffortBudget rows" do
  include CoordinatorRoleData

  def budgets
    role = agents_bluebook.aggregates.find { |aggregate| aggregate.hecks_name == "Role" }
    role.value_objects.find { |object| object.hecks_name == "EffortBudget" }.members
  end

  def sizes = budgets.map { |row| row[:size] }
  def planner_file = File.read(File.join(CoordinatorRoleData::ROOT, ".claude/agents/planner.md"))

  it "holds the four sizes" do
    expect(sizes).to match_array(%w[lookup comparison pieces coding])
  end

  it "gives every size a reason" do
    expect(budgets.map { |row| row[:reason].to_s.empty? }).to all(be(false))
  end

  it "starts no subagents for a lookup" do
    expect(budgets.find { |row| row[:size] == "lookup" }[:subagents]).to eq(0)
  end

  it "starts at most three subagents at any size" do
    expect(budgets.map { |row| row[:subagents] }).to all(be <= 3)
  end

  it "is named, every size, in the orchestrator and planner files" do
    expect(sizes.map { |size| [role_file, planner_file].all? { |file| file.include?(size) } }).to all(be(true))
  end
end
