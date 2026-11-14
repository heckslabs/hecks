require "spec_helper"
require "hecks/agents/adapters/routing_guard"

# The owner-launched `orchestrator-owner` role has every tool and no routing rows; the pipeline's
# `orchestrator` keeps its rows and its one tool. Nothing here touches a live ledger or tap.
RSpec.describe "the orchestrator-owner role" do
  let(:root)  { InMemoryDomain::ROOT }
  let(:guard) { Hecks::Adapters::RoutingGuard.new }

  def routing_rows
    bluebook = Hecks.describe(File.join(root, "lib/hecks/agents")).registry.bluebooks.fetch("Agents")
    role = bluebook.aggregates.find { |aggregate| aggregate.hecks_name == "Role" }
    role.value_objects.find { |object| object.hecks_name == "RoutingRule" }.members
  end

  def verdict(role, command) = guard.guard(role: { value: role }, command: { value: command })

  def agent_file(role) = File.read(File.join(root, ".claude/agents/#{role}.md"))

  it "has no routing rows" do
    expect(routing_rows.map { |row| row[:role] }).not_to include("orchestrator-owner")
  end

  it "is allowed an arbitrary command" do
    expect { verdict("orchestrator-owner", "git push origin main") }.not_to raise_error
  end

  it "leaves the orchestrator its routing rows" do
    expect(routing_rows.count { |row| row[:role] == "orchestrator" }).to be > 40
  end

  it "still refuses the orchestrator a command off its list" do
    expect { verdict("orchestrator", "git push origin main") }
      .to raise_error(Hecks::Adapters::RoutingGuard::Refused)
  end

  it "generates tools * for the owner role" do
    expect(agent_file("orchestrator-owner")).to match(/^tools: \*$/)
  end

  it "keeps tools Bash for the orchestrator" do
    expect(agent_file("orchestrator")).to match(/^tools: Bash$/)
  end
end
