require_relative "lifecycle_checks"

module Hecks
  module Bluebook
    module ModelCheck
      # The checks over an aggregate's size: one that keeps collecting commands, entities and
      # states usually holds more than one consistency boundary (ADR 0137). Its lifecycle states
      # are counted with {LifecycleChecks#full_states}, so the two come together.
      module AggregateChecks
        include LifecycleChecks

        # How much an aggregate may declare before it is reported: its commands, entities and
        # lifecycle states, counted together.
        LARGE_AGGREGATE_LIMIT = 40

        # How many of the least-attached commands the message names.
        SUGGESTED_COMMANDS = 3

        # @param bluebook [Bluebook::Declaration] the assembled bluebook to check
        # @param limit [Integer] the weight an aggregate may reach before it is reported
        # @return [Array<Finding>] one :large_aggregate warning per aggregate over the limit
        def large_aggregate_findings(bluebook, limit: LARGE_AGGREGATE_LIMIT)
          bluebook.aggregates.filter_map { |aggregate| large_aggregate_finding(aggregate, limit) }
        end

        # @return [Finding, nil] the warning for an aggregate heavier than `limit`
        def large_aggregate_finding(aggregate, limit)
          weight = aggregate_weight(aggregate)
          return unless weight > limit
          return if Acknowledgements.held?(aggregate, :large_aggregate)

          Finding.new(kind: :large_aggregate, severity: :warning, subject: aggregate.hecks_name,
                      message: "declares #{weight} commands, entities and states together, past the " \
                               "limit of #{limit} — it may hold more than one consistency boundary" \
                               "#{loosest_commands_hint(aggregate)}")
        end

        # @return [Integer] the aggregate's commands, entities and states, counted together
        def aggregate_weight(aggregate)
          aggregate.commands.size + aggregate.entities.size + lifecycle_state_count(aggregate.lifecycle)
        end

        # @return [Integer] the states the lifecycle names, or zero without one
        def lifecycle_state_count(lifecycle)
          lifecycle ? full_states(lifecycle).size : 0
        end

        # The commands that set the fewest of the aggregate's own fields are the likeliest to
        # belong to another aggregate, so the message names them.
        #
        # @return [String] a clause naming those commands, or an empty string if none set a field
        def loosest_commands_hint(aggregate)
          loosest = aggregate.commands.reject { |command| fields_set_by(command).empty? }
                             .min_by(SUGGESTED_COMMANDS) { |command| fields_set_by(command).size }
          return "" if loosest.empty?

          "; the commands setting the fewest fields are #{loosest.map(&:hecks_name).join(", ")}"
        end

        # @return [Array<String>] the own fields a command sets; a delegation names none of its own
        def fields_set_by(command)
          own = command.mutations.reject { |mutation| mutation.op == :delegate }
          own.map { |mutation| mutation.target.to_s }.uniq
        end
      end
    end
  end
end
