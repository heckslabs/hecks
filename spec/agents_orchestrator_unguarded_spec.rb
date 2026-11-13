require "spec_helper"
require "hecks/agents/adapters/routing_guard"

# The orchestrator has every tool and an unguarded shell: the Agents bluebook holds no routing,
# flag or refusal rows for it, so the Role.guard query allows any command it is asked about.
RSpec.describe "the orchestrator's full permissions" do
  let(:root)  { InMemoryDomain::ROOT }
  let(:guard) { Hecks::Adapters::RoutingGuard.new }

  def role_table(name)
    bluebook = Hecks.describe(File.join(root, "lib/hecks/agents")).registry.bluebooks.fetch("Agents")
    role = bluebook.aggregates.find { |aggregate| aggregate.hecks_name == "Role" }
    role.value_objects.find { |object| object.hecks_name == name }.members
  end

  %w[RoutingRule ShellFlagRule RefusalHint].each do |table|
    it "holds no #{table} row for the orchestrator" do
      expect(role_table(table).select { |row| row[:role] == "orchestrator" }).to be_empty
    end
  end

  it "allows any command, including a push and a discard", :aggregate_failures do
    ["git push origin main", "exe/hecks Landing.discard! branch.value=x", "cat lib/hecks.rb", "claude stop abc"].each do |command|
      expect(guard.guard(role: { value: "orchestrator" }, command: { value: command })).to eq(text: "allowed")
    end
  end

  it "gives the role file every tool" do
    file = File.read(File.join(root, ".claude/agents/orchestrator.md"))
    expect(file).to match(/^tools: \*$/)
  end

  it "ends every reply with the board snapshot" do
    expect(File.read(File.join(root, ".claude/agents/orchestrator.md"))).to include("PipelineBoard.snapshot width.value=120")
  end
end
