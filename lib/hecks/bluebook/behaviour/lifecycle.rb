module Hecks
  module Bluebook
    module Behaviour
      # Readings over a lifecycle's field, starting state and transition list.
      module Lifecycle
        # Every state this lifecycle can be in.
        #
        # @return [Array<String>] the default plus each transition's target, deduplicated
        def states
          ([default] + transitions.map { |_command, t| t.target }).uniq
        end

        # Every transition a command declares.
        #
        # @param command [String, Symbol]
        # @return [Array<Bluebook::StateTransition>]
        def transitions_for(command)
          transitions.select { |name, _| name == command.to_s }.map { |_, t| t }
        end

        # The state a command moves the record to.
        #
        # @param command [String, Symbol]
        # @param current_state [String, Symbol, nil] picks the transition that admits it;
        #   `nil` takes the first declared transition
        # @return [String, nil] `nil` when `command` declares no transition
        # @raise [Runtime::WiringError] if transitions are declared but none admits `current_state`
        def target_for(command, current_state = nil)
          match_transition(command, current_state)&.target
        end

        private

        # A transition whose `from` names several states becomes one row per source state.
        def expand(command, transition)
          sources = transition.from.nil? ? [nil] : Array(transition.from)

          sources.map do |source|
            { command: command, to_state: transition.target, from_state: source }
          end
        end

        def match_transition(command, current_state)
          matches = transitions_for(command)
          return nil if matches.empty?
          return matches.first unless current_state

          # No `|| matches.first`: that would return a target command dispatch refuses.
          # `CommandRules::Admissibility#admissible_transition` owns the real refusal.
          matches.find { |t| applies_from?(t, current_state) } ||
            raise(Runtime::WiringError,
                  "no transition for #{command.inspect} admits state #{current_state.inspect} " \
                  "— add a from: covering it, or check admissibility before calling #target_for")
        end

        def applies_from?(transition, current)
          return true unless transition.from

          Array(transition.from).map(&:to_s).include?(current.to_s)
        end
      end
    end
  end
end
