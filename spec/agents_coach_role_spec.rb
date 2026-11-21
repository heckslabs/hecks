require "spec_helper"
require_relative "support/role_file_slices"

# The coach is a role that relays Miette and nothing more: it may ask, forward, decline and message,
# and is given no way to land, push, stop a run or write her coaching for her.
RSpec.describe "the coach role" do
  include RoleFileSlices

  let(:agents) { File.join(InMemoryDomain::ROOT, "lib/hecks/agents") }
  let(:role) { Hecks.describe(agents).registry.bluebooks.fetch("Agents").aggregates.find { |a| a.hecks_name == "Role" } }
  let(:allowed) do
    rule = role.value_objects.find { |object| object.hecks_name == "RoutingRule" }
    rule.members.select { |row| row[:role] == "coach" }.map { |row| row[:pattern] }
  end

  it "has its role file" do
    expect(File).to exist(File.join(RoleFileSlices::AGENTS, "coach.md"))
  end

  it "may relay a question and her answer", :aggregate_failures do
    expect(allowed).to include("Relay.ask!", "Relay.forward!", "Relay.decline!", "Message.send!", "Message.inbox")
  end

  it "may not land, push, stop a run or write her coaching", :aggregate_failures do
    expect(allowed).not_to include("Landing.land!", "SendTrain.board!", "AgentRun.retire!", "Coaching.advise!")
  end
end
