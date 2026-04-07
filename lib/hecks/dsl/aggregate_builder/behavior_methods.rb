# Hecks::DSL::AggregateBuilder::BehaviorMethods
#
# Command, policy, lifecycle, event subscriber, and specification
# DSL methods extracted from AggregateBuilder.
#
module Hecks
  module DSL
    class AggregateBuilder
      module BehaviorMethods
        # Define a command that can be issued against this aggregate.
        #
        # @param name [String] the command name (e.g. "CreatePizza")
        # @yield block evaluated in the context of CommandBuilder
        # @return [void]
        def command(name, &block)
          builder = CommandBuilder.new(name)
          builder.instance_eval(&block) if block
          @commands << builder.build
        end

        # Define a guard or reactive policy on this aggregate.
        #
        # Guard (arity > 0): block receives command, acts as pre-check.
        # Reactive (arity == 0): block configures event→command wiring.
        #
        # @param name [String] the policy name
        # @yield guard block or reactive wiring block
        # @return [void]
        def policy(name, &block)
          if block && block.arity > 0
            @policies << DomainModel::Behavior::Policy.new(name: name, block: block)
          else
            builder = PolicyBuilder.new(name)
            builder.instance_eval(&block) if block
            @policies << builder.build
          end
        end

        # Define a state machine lifecycle on the given field.
        #
        # @param field [Symbol] the state attribute (e.g. :status)
        # @param default [String] the initial state value
        # @yield block evaluated in LifecycleBuilder context
        # @return [void]
        def lifecycle(field, default:, &block)
          builder = LifecycleBuilder.new(field, default: default)
          builder.instance_eval(&block) if block
          @lifecycle = builder.build
        end

        # Subscribe to a domain event.
        #
        # @param event_name [Symbol, String] the event to listen for
        # @param async [Boolean] whether to run asynchronously
        # @yield handler block
        # @return [void]
        def on_event(event_name, async: false, &block)
          name = generate_subscriber_name(event_name.to_s)
          @subscribers << DomainModel::Behavior::EventSubscriber.new(
            name: name, event_name: event_name.to_s, block: block, async: async
          )
        end

        # Define a reusable specification predicate.
        #
        # @param name [Symbol, String] the specification name
        # @yield block that receives an aggregate instance and returns true/false
        # @return [void]
        def specification(name, &block)
          @specifications << DomainModel::Behavior::Specification.new(name: name, block: block)
        end

        private

        def generate_subscriber_name(event_name)
          base = "On#{event_name}"
          existing = @subscribers.count { |s| s.event_name == event_name }
          existing.zero? ? base : "#{base}#{existing + 1}"
        end
      end
    end
  end
end
