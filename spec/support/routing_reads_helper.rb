require "hecks/agents/adapters/routing_guard"

# Asks the orchestrator's routing guard about one command, as the hook does.
module RoutingReadsHelper
  def guard = (@guard ||= Hecks::Adapters::RoutingGuard.new)

  def verdict(command, agent: nil)
    guard.guard(role: { value: "orchestrator" }, command: { value: command }, agent: agent)
  end

  def refusal(command, agent: nil)
    verdict(command, agent: agent)
  rescue Hecks::Adapters::RoutingGuard::Refused => e
    e.message
  end
end
