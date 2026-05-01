module Hecks
  module Generators
    module Domain
    # Hecks::Generators::Domain::SubscriberGenerator
    #
    # Generates subscriber classes nested under Aggregate::Subscribers.
    # Each subscriber declares +EVENT+ and +ASYNC+ constants, and a +call+
    # method whose body is extracted from the DSL block. Subscribers react
    # to domain events and execute side effects (e.g., sending notifications,
    # updating external systems).
    #
    # The +EVENT+ constant identifies which event the subscriber listens for.
    # The +ASYNC+ constant indicates whether the subscriber should be dispatched
    # asynchronously by the event bus.
    #
    # Part of Generators::Domain, consumed by DomainGemGenerator and InMemoryLoader.
    #
    # == Usage
    #
    #   gen = SubscriberGenerator.new(sub, domain_module: "PizzasDomain", aggregate_name: "Pizza")
    #   gen.generate
    #
    class SubscriberGenerator

      # Initializes the subscriber generator.
      #
      # @param subscriber [Object] the subscriber model object; provides +name+,
      #   +event_name+, +async+, and +block+
      # @param domain_module [String] the Ruby module name to wrap the generated class in
      # @param aggregate_name [String] the name of the parent aggregate class
      def initialize(subscriber, domain_module:, aggregate_name:)
        @subscriber = subscriber
        @domain_module = domain_module
        @aggregate_name = aggregate_name
      end

      # Generates the full Ruby source code for the subscriber class.
      #
      # Produces a class nested under +Aggregate::Subscribers+ with:
      # - +EVENT+ constant for the subscribed event name
      # - +ASYNC+ constant for async dispatch flag
      # - Class-level +.event+ and +.async+ accessor methods
      # - A +call+ instance method with the DSL block's parameters and body
      #
      # @return [String] the generated Ruby source code, newline-terminated
      def generate
        lines = []
        lines << "module #{@domain_module}"
        lines << "  class #{@aggregate_name}"
        lines << "    module Subscribers"
        lines << "      class #{@subscriber.name}"
        lines << "        EVENT = \"#{@subscriber.event_name}\""
        lines << "        ASYNC = #{@subscriber.async}"
        lines << ""
        lines << "        def self.event = EVENT"
        lines << "        def self.async = ASYNC"
        lines << ""
        lines << "        def call#{call_params}"
        lines << "          #{call_body}"
        lines << "        end"
        lines << "      end"
        lines << "    end"
        lines << "  end"
        lines << "end"
        lines.join("\n") + "\n"
      end

      private

      # Formats the parameter list for the +call+ method.
      #
      # @return [String] formatted parameter list (e.g., "(event)") or empty string
      #   if the block takes no parameters
      def call_params
        params = @subscriber.block&.parameters&.map { |_, name| name.to_s } || []
        return "" if params.empty?
        "(#{params.join(", ")})"
      end

      # Extracts the source code from the subscriber's DSL block.
      #
      # @return [String] the block's source code as a string
      def call_body
        Hecks::Utils.block_source(@subscriber.block)
      end
    end
    end
  end
end
