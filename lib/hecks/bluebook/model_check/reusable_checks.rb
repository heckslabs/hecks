module Hecks
  module Bluebook
    module ModelCheck
      # The checks over a lifecycle's `:reusable` mark. A reusable state names an occupant that has
      # ended, so a new record may take its id and the occupant is archived; a state that is still
      # live must never carry the mark.
      module ReusableChecks
        # @return [Array<Finding>] one finding per `:reusable` state that is not declared, and
        #   one per `:reusable` state that is live
        def reusable_findings(lifecycle, subject)
          [*reusable_unknown_findings(lifecycle, subject), *reusable_live_findings(lifecycle, subject)]
        end

        # @return [Array<String>] the states the lifecycle marks `:reusable`
        def reusable_states(lifecycle) = lifecycle.marked(:reusable) || []

        # Finds every `:reusable` state the lifecycle never declares.
        def reusable_unknown_findings(lifecycle, subject)
          (reusable_states(lifecycle) - full_states(lifecycle)).map do |state|
            Finding.new(kind: :reusable_unknown_state, severity: :error, subject: subject,
                        message: "#{state.inspect} is marked :reusable but is not a state of the lifecycle")
          end
        end

        # Finds every declared `:reusable` state that is live: the default a new record starts in,
        # or one a constrained transition leaves.
        def reusable_live_findings(lifecycle, subject)
          declared = reusable_states(lifecycle) & full_states(lifecycle)
          declared.select { |state| live_state?(lifecycle, state) }.map do |state|
            Finding.new(kind: :reusable_live_state, severity: :error, subject: subject,
                        message: "#{state.inspect} is marked :reusable but a record is still live in it — " \
                                 "mark only states where the occupant has ended")
          end
        end

        # @return [Boolean] whether the state is the lifecycle's default or a transition leaves it
        def live_state?(lifecycle, state)
          state == lifecycle.default || leaves?(lifecycle, state)
        end
      end
    end
  end
end
