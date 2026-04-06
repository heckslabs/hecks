# Hecks::CLI::DomainInspector::AggregateFormatter::LifecycleFormatter
#
# Formats the lifecycle (state machine) section of an aggregate, including
# states, transitions, and constrained transitions. Mixed into
# AggregateFormatter to keep concerns separated.
#
#   include LifecycleFormatter
#
module Hecks
  class CLI
    class DomainInspector
      class AggregateFormatter
        module LifecycleFormatter
          private

          def format_lifecycle
            lc = @agg.lifecycle
            return [] unless lc
            lines = ["  Lifecycle:"]
            lines << "    field: #{lc.field}, default: #{lc.default.inspect}"
            lines << "    states: #{lc.states.join(', ')}"
            lines << "    transitions:"
            lc.transitions.each do |cmd, transition|
              lines << format_transition(cmd, transition)
            end
            lines << ""
          end

          def format_transition(cmd, transition)
            if transition.respond_to?(:constrained?) && transition.constrained?
              "      #{cmd} -> #{transition.target} (from: #{transition.from})"
            else
              target = transition.respond_to?(:target) ? transition.target : transition.to_s
              "      #{cmd} -> #{target}"
            end
          end
        end
      end
    end
  end
end
