require "spec_helper"
require_relative "support/role_file_slices"

# Every existing agent file is a `RoleFile` row of the Role aggregate, word for word, and the
# rows name the same roles as the world's `agent_roles` line.
RSpec.describe "the Role aggregate's RoleFile rows" do
  include RoleFileSlices

  it "loads one row for each role the world pins" do
    expect(rows.keys).to match_array(world_roles)
  end

  %w[planner orchestrator architect coder reviewer release_manager pruner].each do |name|
    it "holds the head of #{name} word for word" do
      expect(rows.fetch(name).slice(:description, :tools, :model, :purpose)).to eq(head_of(slices(name)))
    end

    it "holds the body of #{name} word for word" do
      expect(rows.fetch(name).slice(:steps, :rules, :handback)).to eq(body_slices(slices(name)))
    end
  end
end
