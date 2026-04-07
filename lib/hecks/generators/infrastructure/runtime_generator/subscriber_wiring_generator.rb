module Hecks
  module Generators
    module Infrastructure
    # Hecks::Generators::Infrastructure::SubscriberWiringGenerator
    #
    # Generates a static module that wires event subscribers to the event
    # bus for every aggregate in the domain. Replaces the hand-written
    # Hecks::Runtime::SubscriberSetup mixin which iterates the domain IR
    # at boot time. The generated module eliminates runtime IR traversal
    # by emitting one explicit subscribe call per subscriber.
    #
    # Handles both sync and async subscribers. Async subscribers delegate
    # to +@async_handler+ when one is registered; sync subscribers call
    # the handler directly. Domain-level event subscribers (block-based)
    # are not included — they remain dynamic since they capture closures.
    #
    # == Usage
    #
    #   gen = SubscriberWiringGenerator.new(domain, domain_module: "PizzasDomain")
    #   gen.generate
    #   # => "module Hecks\n  class Runtime\n    module Generated\n      module SubscriberWiring\n  ..."
    #
    class SubscriberWiringGenerator < Hecks::Generator

      # Initializes the generator with a domain IR and module name.
      #
      # @param domain [Hecks::DomainModel::Structure::Domain] the domain IR
      #   providing +aggregates+ with +subscribers+ to wire
      # @param domain_module [String] the PascalCase domain module name
      #   (e.g. +"PizzasDomain"+)
      def initialize(domain, domain_module:)
        @domain = domain
        @domain_module = domain_module
      end

      # Generates Ruby source for the SubscriberWiring module.
      #
      # Produces a module under +Hecks::Runtime::Generated+ containing a
      # private +setup_subscribers+ method. Each aggregate's subscribers
      # get an explicit +@event_bus.subscribe+ call that instantiates the
      # subscriber class and delegates events to it.
      #
      # @return [String] the complete Ruby source code, newline-terminated
      def generate
        lines = []
        lines << "module Hecks"
        lines << "  class Runtime"
        lines << "    module Generated"
        lines << "      module SubscriberWiring"
        lines << "        private"
        lines << ""
        lines << "        def setup_subscribers"
        first_agg = true
        @domain.aggregates.each do |agg|
          next if agg.subscribers.empty?
          safe_name = domain_constant_name(agg.name)
          lines << "" unless first_agg
          lines << "          # #{safe_name} subscribers"
          agg.subscribers.each do |sub|
            lines.concat(subscriber_lines(safe_name, sub))
          end
          first_agg = false
        end
        lines << ""
        lines << "          setup_domain_event_subscribers"
        lines << "        end"
        lines << "      end"
        lines << "    end"
        lines << "  end"
        lines << "end"
        lines.join("\n") + "\n"
      end

      private

      # Generates the subscribe block lines for a single subscriber.
      #
      # @param safe_name [String] PascalCase aggregate name
      # @param sub [Object] subscriber IR with +name+, +event_name+, and +async+
      # @return [Array<String>] indented lines for the subscribe call
      def subscriber_lines(safe_name, sub)
        fqn = "#{@domain_module}::#{safe_name}::Subscribers::#{sub.name}"
        lines = []
        lines << "          handler_#{underscore(sub.name)} = #{fqn}.new"
        lines << "          @event_bus.subscribe(\"#{sub.event_name}\") do |event|"
        if sub.async
          lines << "            if @async_handler"
          lines << "              @async_handler.call(\"#{fqn}\", event)"
          lines << "            else"
          lines << "              handler_#{underscore(sub.name)}.call(event)"
          lines << "            end"
        else
          lines << "            handler_#{underscore(sub.name)}.call(event)"
        end
        lines << "          end"
        lines
      end

      # Converts a PascalCase name to snake_case for local variable names.
      #
      # @param name [String] PascalCase name (e.g. "NotifyKitchen")
      # @return [String] snake_case name (e.g. "notify_kitchen")
      def underscore(name)
        name.to_s
            .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
            .gsub(/([a-z\d])([A-Z])/, '\1_\2')
            .downcase
      end
    end
    end
  end
end
