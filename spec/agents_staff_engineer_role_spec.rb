require "spec_helper"
require_relative "support/role_file_slices"

# The staff engineer is the seat Miette holds: it relays her and nothing more, and may send, list
# and read messages. It is given no way to land, push, stop a run or write her coaching for her.
RSpec.describe "the staff engineer role" do
  include RoleFileSlices

  let(:agents) { File.join(InMemoryDomain::ROOT, "lib/hecks/agents") }
  let(:role) { Hecks.describe(agents).registry.bluebooks.fetch("Agents").aggregates.find { |a| a.hecks_name == "Role" } }
  let(:rule) { role.value_objects.find { |object| object.hecks_name == "RoutingRule" } }
  let(:roles) { rule.members.map { |row| row[:role] } }
  let(:allowed) { rule.members.select { |row| row[:role] == "staff-engineer" }.map { |row| row[:pattern] } }

  it "is registered and the coach is not", :aggregate_failures do
    expect(roles).to include("staff-engineer")
    expect(roles).not_to include("coach")
  end

  it "has its role file and the coach's is gone", :aggregate_failures do
    expect(File).to exist(File.join(RoleFileSlices::AGENTS, "staff-engineer.md"))
    expect(File).not_to exist(File.join(RoleFileSlices::AGENTS, "coach.md"))
  end

  it "is guarded in place of the coach", :aggregate_failures do
    guarded = File.read(File.join(InMemoryDomain::ROOT, ".claude/hooks/guarded_roles")).split
    expect(guarded).to include("staff-engineer")
    expect(guarded).not_to include("coach")
  end

  it "may relay a question and her answer", :aggregate_failures do
    expect(allowed).to include("Message.send!", "Message.inbox", "Message.read!")
  end

  it "may not land, push, stop a run or write her coaching", :aggregate_failures do
    expect(allowed).not_to include("Landing.land!", "SendTrain.board!", "AgentRun.retire!", "Coaching.advise!", "Relay.forward!")
  end
end
