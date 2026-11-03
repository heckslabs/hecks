require_relative "../ask_resolution"
require_relative "reaction_cycles"
require_relative "reaction_walk"

module Hecks
  module Bluebook
    module ModelCheck
      # The reaction graph of one bluebook: which verb emits which event, which policy reacts to
      # it, and which verb that policy dispatches in turn, an `ask` resolved through the
      # hecksagon to its port operation. `from` walks it to the longest chain a verb's events start.
      #
      # A policy already on the path is not followed again: a loop is cut where it closes, so a
      # chain counts each policy once; `cycles` reports the loops themselves. A cross-domain
      # (`across`) policy ends a chain, since the other domain's policies are not in this
      # bluebook. A `where` is not evaluated, so a chain is the deepest one the declarations
      # allow, not one a run is certain to take.
      class ReactionChains
        # One reaction step: the policy that fires and the verb it dispatches.
        Step = Struct.new(:policy, :verb) do
          # @return [String] the policy's name
          def policy_name = policy.name
        end

        # @param bluebook [Bluebook::Declaration] the assembled bluebook, its hecksagon attached
        def initialize(bluebook)
          @bluebook  = bluebook
          @emitted   = emitted_by_verb
          @policies  = bluebook.policies.reject(&:target_domain)
          @dispatch  = @policies.to_h { |policy| [policy, dispatched_by(policy)] }
          @successors = @policies.to_h { |policy| [policy, @dispatch[policy] ? reacting_to(@dispatch[policy]) : []] }
        end

        # @return [Array<Array<String>>] each verb that emits an event, as split_verb parses it
        def verbs = @emitted.keys

        # @return [Set<Array>] the verbs some policy dispatches, which a longer chain already covers
        def reaction_targets = @dispatch.values.compact.to_set

        # @param verb [Array<String>] a verb, as `Naming.split_verb` parses it
        # @return [Array<Step>] the longest chain of reactions the verb's events start, in order
        def from(verb) = walk.longest(reacting_to(verb))

        # @return [Boolean] whether the last `from` stopped searching, so its chain is a lower bound
        def capped? = walk.capped?

        # @return [Array<Array>] each loop in the graph, as the policies that reach one another
        def cycles = @cycles ||= ReactionCycles.new(@policies, @successors).groups

        # @param policy [Object] a policy of this bluebook
        # @return [Step] the policy with the verb it dispatches
        def step(policy) = Step.new(policy, @dispatch[policy])

        # @param policy [Object] a policy of this bluebook
        # @return [Array] the policies the verb it dispatches starts
        def successors(policy) = @successors.fetch(policy)

        private

        def walk = @walk ||= ReactionWalk.new(self, cycles.flatten)

        # Policies that react to an event the verb emits.
        def reacting_to(verb)
          events = @emitted.fetch(verb, [])
          @policies.select { |policy| events.any? { |aggregate, event| hears?(policy, aggregate, event) } }
        end

        def hears?(policy, aggregate, event)
          return false unless policy.event_name == event

          qualifier = policy.event_qualifier
          qualifier.nil? || Naming.demodulise(qualifier) == aggregate
        end

        def dispatched_by(policy)
          verb = policy.asks? ? asked_verb(policy) : "#{@bluebook.name}::#{policy.trigger_command}"
          Naming.split_verb(verb) if verb
        end

        # The port operation an `ask` resolves to, spelled as a trigger names it, or nil.
        def asked_verb(policy)
          outcome = AskResolution.call(@bluebook, policy)
          "#{@bluebook.name}::#{outcome.verb}" if outcome.resolved?
        end

        # Each verb the bluebook declares to the `[aggregate, event]` pairs it announces.
        def emitted_by_verb
          @bluebook.aggregates.each_with_object({}) do |aggregate, held|
            commands_of(aggregate).each { |verb, events| held[verb] = events.map { |event| [aggregate.hecks_name, event] } }
          end
        end

        def commands_of(aggregate)
          prefix = "#{@bluebook.name}::#{aggregate.hecks_name}"
          [*aggregate.commands.map { |command| ["#{prefix}.#{command.hecks_name}", command.emits] },
           *aggregate.entities.flat_map { |entity| entity_commands(prefix, entity) },
           *aggregate.ports.flat_map { |port| operations(prefix, port) }]
            .to_h { |verb, events| [Naming.split_verb(verb), bare_names(events)] }
        end

        def bare_names(events) = Array(events).map { |event| event.to_s.split("::").last }

        def entity_commands(prefix, entity)
          entity.commands.map { |command| ["#{prefix}.#{entity.hecks_name}.#{command.hecks_name}", command.emits] }
        end

        def operations(prefix, port)
          port.operations.map do |operation|
            ["#{prefix}.#{port.name}.#{operation.hecks_name}", [*operation.emits, operation.answers, operation.refuses].compact]
          end
        end
      end
    end
  end
end
