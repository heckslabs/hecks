module Hecks
  module Generators
    module Domain
    # Hecks::Generators::Domain::EventGenerator
    #
    # Generates frozen domain event classes nested under Aggregate::Events.
    # Each event records an +occurred_at+ timestamp and freezes on creation,
    # making events immutable value objects that capture what happened in the domain.
    # Handles Ruby keyword-safe attribute names via **kwargs. Part of
    # Generators::Domain, consumed by DomainGemGenerator and InMemoryLoader.
    #
    # The generated class includes:
    # - +attr_reader+ for all event attributes plus +:occurred_at+
    # - An +initialize+ method that sets all attributes, records +Time.now+, and freezes
    # - Keyword parameters or +**kwargs+ depending on attribute name safety
    #
    # == Usage
    #
    #   gen = EventGenerator.new(event, domain_module: "PizzasDomain", aggregate_name: "Pizza")
    #   gen.generate  # => "module PizzasDomain\n  class Pizza\n    module Events\n  ..."
    #
    class EventGenerator

      # Initializes the event generator.
      #
      # @param event [Object] the event model object; provides +name+ and +attributes+
      # @param domain_module [String] the Ruby module name to wrap the generated class in
      # @param aggregate_name [String] the name of the parent aggregate class
      def initialize(event, domain_module:, aggregate_name:)
        @event = event
        @domain_module = domain_module
        @aggregate_name = aggregate_name
        @has_keyword_attrs = @event.attributes.any? { |a| Hecks::Utils.ruby_keyword?(a.name) }
      end

      # Generates the full Ruby source code for the domain event class.
      #
      # Produces a class nested under +Aggregate::Events+ with attr_readers,
      # a constructor that sets all attributes and freezes, and an +occurred_at+
      # timestamp.
      #
      # @return [String] the generated Ruby source code, newline-terminated
      def generate
        lines = []
        lines << "module #{@domain_module}"
        lines << "  class #{@aggregate_name}"
        lines << "    module Events"
        lines << "      class #{@event.name}"
        lines << "        attr_reader #{@event.attributes.map { |a| ":#{a.name}" }.join(", ")}, :occurred_at"
        lines << ""
        if @has_keyword_attrs
          lines << "        def initialize(**kwargs)"
          @event.attributes.each do |attr|
            lines << "          @#{attr.name} = kwargs[:#{attr.name}]"
          end
        else
          lines << "        def initialize(#{constructor_params})"
          @event.attributes.each do |attr|
            lines << "          @#{attr.name} = #{attr.name}"
          end
        end
        lines << "          @occurred_at = Time.now"
        lines << "          freeze"
        lines << "        end"
        lines << "      end"
        lines << "    end"
        lines << "  end"
        lines << "end"
        lines.join("\n") + "\n"
      end

      private

      # Builds the constructor parameter string for named keyword parameters.
      #
      # Each event attribute becomes a keyword parameter defaulting to nil.
      #
      # @return [String] comma-separated keyword parameters (e.g., "name: nil, size: nil")
      def constructor_params
        @event.attributes.map { |attr| "#{attr.name}: nil" }.join(", ")
      end
    end
    end
  end
end
