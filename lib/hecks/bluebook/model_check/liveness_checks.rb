require_relative "liveness/passage"
require_relative "liveness/timeout_row_checks"

module Hecks
  module Bluebook
    module ModelCheck
      # The checks over where a record can wait. A state that is not ended (`:terminal` or
      # `:reusable`) is one of three things: passed through by an ask, a rest the lifecycle marks
      # `:rests`, or a wait. A wait needs a timeout row that names it; one with none can hold a
      # record forever.
      #
      # An ask is not a bound: an adapter that hangs answers nothing. It only says the state is
      # left by the same dispatch that entered it, so a row may time a passed-through state too.
      module LivenessChecks
        include TimeoutRowChecks

        # @param bluebook [Bluebook::Declaration] the assembled bluebook to check
        # @param timeouts [Array<Hash{Symbol => Object}>, nil] the timeout rows the bluebook
        #   declares (`kind`, `aggregate` as `Domain::Aggregate`, `state`, `opens`, `closes`,
        #   `ends`); nil for a bluebook that declares none
        # @param held [Boolean] whether a wait no row times is an error; a warning otherwise
        # @return [Array<Finding>] the waits no row times, the rows and the rests that are wrong
        def liveness_findings(bluebook, timeouts, held: false)
          rows = state_rows(bluebook, timeouts)
          known = bluebook.aggregates.select(&:lifecycle)
          strays = rows.keys - known.map(&:hecks_name)
          [*strays.flat_map { |name| rows[name].map { |row| unknown_timeout_state(row) } },
           *known.flat_map { |aggregate| aggregate_liveness(bluebook, aggregate, rows, held) }]
        end

        # The rows that name a state of one of this bluebook's aggregates, by aggregate name.
        #
        # @return [Hash{String => Array<Hash>}]
        def state_rows(bluebook, timeouts)
          own = Array(timeouts).select do |row|
            !row[:state].to_s.empty? && row[:aggregate].to_s.start_with?("#{bluebook.name}::")
          end
          own.group_by { |row| row[:aggregate].to_s.delete_prefix("#{bluebook.name}::") }
        end

        # @return [Array<Finding>] one aggregate's rest, wait and row findings
        def aggregate_liveness(bluebook, aggregate, rows, held)
          lifecycle = aggregate.lifecycle
          passage   = Passage.new(bluebook, aggregate)
          timed     = rows.fetch(aggregate.hecks_name, [])
          [*rest_findings(lifecycle, passage, timed, aggregate.hecks_name),
           *wait_findings(lifecycle, passage, timed, aggregate.hecks_name, held),
           *timed.flat_map { |row| timeout_row_findings(passage, full_states(lifecycle), row) }]
        end

        # @return [Array<String>] the states the lifecycle marks `:rests`
        def resting_states(lifecycle) = lifecycle.marked(:rests) || []

        # @return [Array<String>] the states whose occupant has ended
        def ended_states(lifecycle) = terminal_states(lifecycle) + (lifecycle.marked(:reusable) || [])

        # Finds every state a record can be left in that nothing carries out and no row times.
        def wait_findings(lifecycle, passage, timed, subject, held)
          open = full_states(lifecycle) - ended_states(lifecycle) - resting_states(lifecycle) -
                 timed.map { |row| row[:state].to_s }
          open.reject { |state| passage.passed_through?(state) }.map do |state|
            Finding.new(kind: :wait_without_timeout, severity: held ? :error : :warning, subject: subject,
                        message: "#{state.inspect} can hold a record forever: no ask carries it out and no " \
                                 "timeout row names it — time it, or `mark :rests, #{state.inspect}` if nothing waits there")
          end
        end

        # Finds every `:rests` mark on a state that is ended, timed or passed through. The builder
        # already refuses a mark on a state the lifecycle does not declare.
        def rest_findings(lifecycle, passage, timed, subject)
          resting_states(lifecycle).filter_map do |state|
            contradiction = rest_contradiction(lifecycle, passage, timed, state)
            next unless contradiction

            Finding.new(kind: :rests_contradicted, severity: :error, subject: subject,
                        message: "#{state.inspect} is marked :rests but #{contradiction}")
          end
        end

        # @return [String, nil] what says a record does not rest in `state`
        def rest_contradiction(lifecycle, passage, timed, state)
          return "its occupant has ended (:terminal or :reusable)" if ended_states(lifecycle).include?(state)
          return "a timeout row times it as a wait" if timed.any? { |row| row[:state].to_s == state }

          "the reactions to entering it carry every record out" if passage.passed_through?(state)
        end
      end
    end
  end
end
