# frozen_string_literal: true

module Hecks
  module Adapters
    class Metering
      # The role Signalbox's laws count a session under (coder, helper, gate, orchestrator or
      # repair), or `person` for a session a person runs by hand, which is the person's own use and
      # not the pipeline's load. A dispatched session's run names its agent; an unrun background
      # session is counted by its name, and is a helper unless it is a copy of the orchestrator seat.
      module SessionRole
        # Names an unrun session takes the orchestrator's seat under.
        SEAT = /\A(orchestrator|coordinator|handrun-orchestrator)/i

        module_function

        # @param entry [Hash] the session as `claude agents --json` lists it
        # @param run [Hash, nil] its AgentRun: `agent:`, `works_as:`, `work:` and `run:`
        # @return [String] the role the laws count it under
        def of(entry, run)
          return by_agent(run[:agent].to_s) if run
          return "person" if entry["kind"].to_s == "interactive"

          entry["name"].to_s.match?(SEAT) ? "orchestrator" : "helper"
        end

        # @return [String] the role it was started to work as: the run's part, else its agent
        def works_as(run)
          return "" unless run

          part = run[:works_as].to_s
          part.empty? ? run[:agent].to_s : part
        end

        def by_agent(agent)
          case agent
          when "coder", "orchestrator" then agent
          else "helper"
          end
        end
      end
    end
  end
end
