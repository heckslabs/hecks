require_relative "../naming"

module Hecks
  module Bluebook
    # Maps a policy's `ask :name` onto the port operation the hecksagon declared for it.
    #
    # The match is by the event's aggregate and the ask's name against that aggregate's declared
    # `asks`. When one aggregate has the same ask name on two ports, the operation the hecksagon
    # marked with `ask_via` is the one; otherwise the ask is ambiguous.
    module AskResolution
      # One ask's outcome: the verb it resolves to, or why it resolves to none.
      #
      # @!attribute [r] verb
      #   @return [String, nil] `Aggregate::Port.Operation` when resolved, spelled as the
      #     `trigger Aggregate::Port::Operation` it stands for is
      # @!attribute [r] problem
      #   @return [Symbol, nil] `:no_aggregate`, `:unmatched` or `:ambiguous` when not
      # @!attribute [r] detail
      #   @return [String, nil] what the refusal says, naming the aggregate and candidates
      Outcome = Struct.new(:verb, :problem, :detail, keyword_init: true) do
        # @return [Boolean] whether the ask resolved to one operation
        def resolved? = problem.nil?
      end

      module_function

      # Resolves one ask policy against a chapter's aggregates and their declared ports.
      #
      # @param chapter [Bluebook::Chapter] the chapter the policy is declared in
      # @param policy [Bluebook::Policy] a policy that `asks?`
      # @return [Outcome] the verb, or the problem
      def call(chapter, policy)
        aggregate = event_aggregate(chapter, policy)
        return no_aggregate(policy) unless aggregate

        found = picked(candidates(aggregate, policy.ask))
        return unmatched(aggregate, policy) if found.empty?
        return ambiguous(aggregate, policy, found) if found.size > 1

        port, operation = found.first
        Outcome.new(verb: "#{aggregate.hecks_name}::#{port.name}.#{operation.hecks_name}")
      end

      # The operations a tie leaves once `ask_via` has spoken: the chosen ones, or all of them
      # when the hecksagon chose none.
      #
      # @return [Array<Array(Bluebook::DomainPort, Bluebook::PortOperation)>]
      def picked(found)
        chosen = found.select { |_port, operation| operation.chosen? }
        found.size > 1 && !chosen.empty? ? chosen : found
      end

      # Binds every ask policy of a chapter that resolves, leaving the rest for the boot gate and
      # `model_check` to name.
      #
      # @param chapter [Bluebook::Chapter] the chapter whose policies to resolve
      # @return [void]
      def bind_resolved(chapter)
        chapter.policies.select(&:asks?).each do |policy|
          outcome = call(chapter, policy)
          policy.resolve_ask!(outcome.verb) if outcome.resolved?
        end
      end

      # Marks the named ask on the named port as the one policies reach, for `ask_via`, and
      # re-binds every ask the pick settles.
      #
      # @param chapter [Bluebook::Chapter, nil] the chapter the aggregate belongs to
      # @param aggregate_name [String] the aggregate declaring the port
      # @param name [String, Symbol] the ask's declared name
      # @param port [String, Symbol] the port whose ask is picked
      # @return [void]
      # @raise [Bluebook::DSL::Malformed] if no such ask is declared on that port yet
      def pick!(chapter, aggregate_name, name, port)
        held = chapter&.aggregate(aggregate_name)&.port(port)
        operation = held&.operation(name)
        unless operation
          raise DSL::Malformed, "#{aggregate_name}.ask_via #{name.to_s.inspect}, port: #{port.to_s.inspect} " \
                                "names no declared ask — declare the port's `asks` before picking it"
        end

        operation.choose!
        bind_resolved(chapter)
      end

      # The aggregate whose event the policy reacts to: the one the event is qualified with, or
      # the one whose commands emit it when the event is written bare.
      #
      # @return [Bluebook::Aggregate, nil]
      def event_aggregate(chapter, policy)
        qualifier = policy.event_qualifier
        return chapter.aggregate(Naming.demodulise(qualifier)) if qualifier

        chapter.aggregates.find do |aggregate|
          aggregate.commands.any? { |command| Array(command.emits).include?(policy.event_name) }
        end
      end

      # @return [Array<Array(Bluebook::DomainPort, Bluebook::PortOperation)>] each outbound
      #   operation on the aggregate's ports the ask name spells
      def candidates(aggregate, ask)
        aggregate.ports.flat_map do |port|
          port.operations.select { |op| op.outbound? && Naming.snake(op.hecks_name) == ask.to_s }
              .map { |operation| [port, operation] }
        end
      end

      def no_aggregate(policy)
        Outcome.new(problem: :no_aggregate,
                    detail:  "#{policy.name}'s ask #{policy.ask.to_sym.inspect} reacts to " \
                             "#{policy.on_event.inspect}, whose aggregate this chapter does not declare")
      end

      def unmatched(aggregate, policy)
        Outcome.new(problem: :unmatched,
                    detail:  "#{policy.name}'s ask #{policy.ask.to_sym.inspect} matches no `asks` declared on " \
                             "#{aggregate.hecks_name} — declare `asks \"#{Naming.pascal(policy.ask)}\"` " \
                             "on one of its ports in the hecksagon")
      end

      def ambiguous(aggregate, policy, found)
        ports = found.map { |port, _operation| port.name.inspect }.join(" and ")
        Outcome.new(problem: :ambiguous,
                    detail:  "#{policy.name}'s ask #{policy.ask.to_sym.inspect} is asked on #{ports} of " \
                             "#{aggregate.hecks_name} — pick one in the hecksagon with " \
                             "`#{aggregate.hecks_name}.ask_via \"#{Naming.pascal(policy.ask)}\", port: \"...\"`")
      end
    end
  end
end
