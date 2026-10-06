module Hecks
  module Bluebook
    module ModelCheck
      # The checks over a lifecycle read as a state machine: states nothing reaches, transitions
      # that can never fire, states nothing leaves, and transitions naming no command.
      module LifecycleChecks
        # Runs every lifecycle-shaped check for one declaring construct — the aggregate
        # itself, or one of its entities — if it declares a lifecycle at all.
        def lifecycle_findings(aggregate, declaring)
          lifecycle = declaring.lifecycle
          return [] unless lifecycle

          subject = lifecycle_subject(aggregate, declaring)
          reached = reachable_states(lifecycle)

          [
            *unknown_transition_commands(lifecycle, Array(declaring.commands).map(&:hecks_name), subject),
            *unreachable_state_findings(lifecycle, full_states(lifecycle), reached, subject),
            *dead_transition_findings(lifecycle, reached, subject),
            *stuck_state_findings(lifecycle, reached, subject)
          ]
        end

        # @return [String] the aggregate's name, or `Aggregate::Entity` for one of its entities
        def lifecycle_subject(aggregate, declaring)
          return aggregate.hecks_name if declaring.equal?(aggregate)

          "#{aggregate.hecks_name}::#{declaring.hecks_name}"
        end

        # Finds every declared state the lifecycle's own reachability walk never reaches.
        def unreachable_state_findings(lifecycle, full, reached, subject)
          (full - reached.to_a).map do |state|
            Finding.new(kind: :unreachable_state, severity: :error, subject: subject,
                        message: "#{state.inspect} is declared (in a transition's from: or target) " \
                                 "but no path from #{lifecycle.default.inspect} ever reaches it")
          end
        end

        # Finds every constrained transition whose from: states are all unreached.
        def dead_transition_findings(lifecycle, reached, subject)
          lifecycle.transitions.filter_map do |command, transition|
            next unless transition.constrained?
            next if Array(transition.from).any? { |source| reached.include?(source) }

            Finding.new(kind: :dead_transition, severity: :error, subject: subject,
                        message: "#{command} from #{Array(transition.from).inspect} can never fire — " \
                                 "none of those states is ever reached")
          end
        end

        # Finds every reached state with no transition ever leaving it, unless any
        # transition in this lifecycle is unconstrained.
        def stuck_state_findings(lifecycle, reached, subject)
          any_unconstrained = lifecycle.transitions.any? { |_, t| !t.constrained? }
          (reached - terminal_exempt(lifecycle)).filter_map do |state|
            next if any_unconstrained
            next if lifecycle.transitions.any? { |_, t| t.constrained? && Array(t.from).include?(state) }

            Finding.new(kind: :stuck_state, severity: :warning, subject: subject,
                        message: "#{state.inspect} is reached but no transition ever leaves it — " \
                                 "fine if that is meant to be terminal")
          end
        end

        # Finds every transition named after a command the construct doesn't declare.
        def unknown_transition_commands(lifecycle, commands, subject)
          lifecycle.transitions.filter_map do |command, _transition|
            next if commands.include?(command)

            Finding.new(kind: :unknown_command, severity: :error, subject: subject,
                        message: "a transition names #{command.inspect}, which this construct declares no command for")
          end
        end

        # Every state `lifecycle` declares in any role — default, target, or from,
        # unique.
        #
        # @param lifecycle [Bluebook::Lifecycle] the lifecycle being checked
        # @return [Array<String>] every state lifecycle declares, unique
        def full_states(lifecycle)
          (
            [lifecycle.default] +
            lifecycle.transitions.map { |_, t| t.target } +
            lifecycle.transitions.flat_map { |_, t| Array(t.from) }
          ).uniq
        end

        # Least fixpoint from the default state: an unconstrained transition always
        # fires; a constrained one fires once any of its named sources is reached.
        def reachable_states(lifecycle)
          reached = Set.new([lifecycle.default])
          # `transitions` is an Array of [from, transition] pairs, not a Hash.
          transitions = lifecycle.transitions.map { |_, transition| transition }
          loop { break unless transitions.map { |transition| reach(transition, reached) }.any? }
          reached
        end

        # Adds `transition`'s target to `reached` when the transition can fire from what is
        # already reached.
        #
        # @return [Set, nil] truthy when the target was newly reached
        def reach(transition, reached)
          return if transition.constrained? && Array(transition.from).none? { |source| reached.include?(source) }

          reached.add?(transition.target)
        end

        # Exempts only the lifecycle's own default state, and only when the lifecycle
        # declares real transitions elsewhere: entering default implies nothing about
        # ever leaving it, unlike a state some transition explicitly delivered to. An
        # empty lifecycle still warns — that reads as unfinished wiring, not a deliberate rest.
        def terminal_exempt(lifecycle)
          return [] if lifecycle.transitions.empty?

          outgoing_sources = lifecycle.transitions.flat_map { |_, t| Array(t.from) }.to_set
          outgoing_sources.include?(lifecycle.default) ? [] : [lifecycle.default]
        end
      end
    end
  end
end
