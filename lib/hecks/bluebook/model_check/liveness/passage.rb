require_relative "../../ask_resolution"

module Hecks
  module Bluebook
    module ModelCheck
      # One aggregate's lifecycle read for how a record gets into and out of each state: the
      # events that enter a state, the events that leave it, and whether the reactions to entering
      # it are sure to move the record out again.
      class Passage
        # @param bluebook [Bluebook::Declaration] the bluebook the aggregate is declared in
        # @param aggregate [Bluebook::Aggregate] an aggregate that declares a lifecycle
        def initialize(bluebook, aggregate)
          @bluebook  = bluebook
          @aggregate = aggregate
          @lifecycle = aggregate.lifecycle
          @commands  = aggregate.commands.to_h { |command| [command.hecks_name, command] }
        end

        # @param state [String] a lifecycle state
        # @return [Array<String>] the events of the commands that put a record in `state`: the
        #   transitions that target it and, for the default state, the commands that create one
        def entering_events(state)
          names = moves.select { |_, transition| transition.target == state }.map(&:first)
          names += creators if state == @lifecycle.default
          events_of(names)
        end

        # @param state [String] a lifecycle state
        # @return [Array<String>] the events of the transitions that move a record out of `state`
        def leaving_events(state) = events_of(leaving(state))

        # Whether every way into `state` starts reactions that are sure to move the record out
        # again: a policy that triggers a transition out of it, or one that asks a port whose
        # answer and refusal each do, through as many asks as it takes. A policy with a `where`
        # or a `for_each` may not fire, so it carries nothing.
        #
        # @param state [String] a lifecycle state
        # @return [Boolean] false for a state nothing enters
        def passed_through?(state)
          events = entering_events(state)
          events.any? && events.all? { |event| carried_out?(event, state, []) }
        end

        private

        def moves = @lifecycle.transitions.map { |command, transition| [command.to_s, transition] }

        def creators = @aggregate.commands.select(&:creates?).map(&:hecks_name) - moves.map(&:first)

        def leaving(state)
          moves.select { |_, t| t.constrained? && Array(t.from).include?(state) && t.target != state }.map(&:first)
        end

        def events_of(names)
          names.flat_map { |name| Array(@commands[name]&.emits) }.map { |event| Naming.unqualified(event.to_s) }.uniq
        end

        # `seen` holds the events already followed, so a loop of asks carries nothing.
        def carried_out?(event, state, seen)
          name = Naming.unqualified(event.to_s)
          return false if name.empty? || seen.include?(name)

          certain(name).any? { |policy| carries?(policy, state, [*seen, name]) }
        end

        def carries?(policy, state, seen)
          return leaving(state).include?(own_tail(policy.trigger_command)) unless policy.asks?

          operation = operation_of(policy)
          !operation.nil? && [operation.answers, operation.refuses].all? { |outcome| carried_out?(outcome, state, seen) }
        end

        # The policies sure to fire on one of this aggregate's events.
        def certain(event)
          @bluebook.policies.select do |policy|
            policy.event_name == event && own_event?(policy) && !policy.guarded? && !policy.fans_out? &&
              !policy.target_domain
          end
        end

        def own_event?(policy)
          owner = policy.event_qualifier.to_s
          owner.empty? || owner.split("::").last == @aggregate.hecks_name
        end

        def operation_of(policy)
          outcome = AskResolution.call(@bluebook, policy)
          return unless outcome.resolved?

          port, operation = own_tail(outcome.verb).to_s.split(".", 2)
          @aggregate.port(port)&.operation(operation)
        end

        # The command part of a verb on this aggregate, nil for a verb on another.
        def own_tail(verb)
          _, aggregate, tail = Naming.split_verb("#{@bluebook.name}::#{verb}")
          tail if aggregate == @aggregate.hecks_name
        end
      end
    end
  end
end
