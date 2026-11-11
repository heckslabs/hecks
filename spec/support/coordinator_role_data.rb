# frozen_string_literal: true

# Reads the orchestrator's rows from the Agents bluebook and its role file, and asks the routing
# guard about a command, for the specs of the coordinator role.
module CoordinatorRoleData
  ROOT = InMemoryDomain::ROOT

  def agents_bluebook = Hecks.describe(File.join(ROOT, "lib/hecks/agents")).registry.bluebooks.fetch("Agents")

  def role_rows(name)
    role = agents_bluebook.aggregates.find { |aggregate| aggregate.hecks_name == "Role" }
    role.value_objects.find { |object| object.hecks_name == name }.members.select { |row| row[:role] == "orchestrator" }
  end

  def role_file = File.read(File.join(ROOT, ".claude/agents/orchestrator.md"))
  def refusal(command) = Hecks::Adapters::RoutingGuard.new.guard(role: "orchestrator", command: command)
  def patterns = role_rows("RoutingRule").map { |row| row[:pattern] }
end
