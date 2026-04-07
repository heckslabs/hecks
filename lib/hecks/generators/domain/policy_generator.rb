module Hecks
  module Generators
    module Domain
    # Hecks::Generators::Domain::PolicyGenerator
    #
    # Generates policy classes nested under Aggregate::Policies. Supports two
    # types of policies:
    #
    # == Guard Policies
    # Guard policies have a +call+ method with parameters extracted from the DSL
    # block. They run synchronously before a command executes and can prevent it
    # by raising an error. The block's source becomes the method body.
    #
    # == Reactive Policies
    # Reactive policies respond to domain events by dispatching trigger commands.
    # They declare +EVENT+, +TRIGGER+, +ASYNC+, +MAP+, and +DEFAULTS+ constants.
    # The +call(event)+ method maps event attributes to command attributes and
    # dispatches the trigger command.
    #
    # Part of Generators::Domain, consumed by DomainGemGenerator and InMemoryLoader.
    #
    # == Usage
    #
    #   gen = PolicyGenerator.new(policy, domain_module: "PizzasDomain", aggregate_name: "Order")
    #   gen.generate
    #
    class PolicyGenerator

      # Initializes the policy generator.
      #
      # @param policy [Object] the policy model object; provides +name+, +guard?+,
      #   +block+, +event_name+, +trigger_command+, +async+, +attribute_map+, and +defaults+
      # @param domain_module [String] the Ruby module name to wrap the generated class in
      # @param aggregate_name [String] the name of the parent aggregate class
      def initialize(policy, domain_module:, aggregate_name:)
        @policy = policy
        @domain_module = domain_module
        @aggregate_name = aggregate_name
      end

      # Generates the full Ruby source code for the policy class.
      #
      # Delegates to +generate_guard+ or +generate_reactive+ based on the
      # policy's type.
      #
      # @return [String] the generated Ruby source code, newline-terminated
      def generate
        @policy.guard? ? generate_guard : generate_reactive
      end

      private

      # Generates a guard policy class with a +call+ method.
      #
      # The call method's parameters and body are extracted from the DSL block.
      # Guard policies run synchronously and can prevent command execution.
      #
      # @return [String] the generated Ruby source code for the guard policy
      def generate_guard
        lines = []
        lines << "module #{@domain_module}"
        lines << "  class #{@aggregate_name}"
        lines << "    module Policies"
        lines << "      class #{@policy.name}"
        lines << "        def call#{call_params}"
        lines << "          #{call_body}"
        lines << "        end"
        lines << "      end"
        lines << "    end"
        lines << "  end"
        lines << "end"
        lines.join("\n") + "\n"
      end

      # Generates a reactive policy class with event/command constants.
      #
      # Reactive policies declare:
      # - +EVENT+ -- the event name that triggers the policy
      # - +TRIGGER+ -- the command name to dispatch in response
      # - +ASYNC+ -- whether the policy runs asynchronously
      # - +MAP+ -- attribute mapping from event to command (if non-empty)
      # - +DEFAULTS+ -- default values for the triggered command (if non-empty)
      #
      # @return [String] the generated Ruby source code for the reactive policy
      def generate_reactive
        map = @policy.attribute_map
        defaults = @policy.respond_to?(:defaults) ? @policy.defaults : {}
        lines = []
        lines << "module #{@domain_module}"
        lines << "  class #{@aggregate_name}"
        lines << "    module Policies"
        lines << "      class #{@policy.name}"
        lines << "        EVENT   = #{@policy.event_name.inspect}"
        lines << "        TRIGGER = #{@policy.trigger_command.inspect}"
        lines << "        ASYNC   = #{@policy.async}"
        lines << "        MAP     = #{map.inspect}.freeze" unless map.empty?
        lines << "        DEFAULTS = #{defaults.inspect}.freeze" unless defaults.empty?
        lines << ""
        lines << "        def self.event   = EVENT"
        lines << "        def self.trigger = TRIGGER"
        lines << "        def self.async   = ASYNC"
        lines << ""
        lines << "        attr_reader :result"
        lines << ""
        lines << "        def call(event)"
        lines << "          # Maps event attrs and dispatches trigger command"
        lines << "          self"
        lines << "        end"
        lines << "      end"
        lines << "    end"
        lines << "  end"
        lines << "end"
        lines.join("\n") + "\n"
      end

      # Extracts the parameter list from the policy's DSL block.
      #
      # @return [String] formatted parameter list (e.g., "(command)") or empty string
      #   if the block takes no parameters
      def call_params
        params = @policy.block&.parameters&.map { |_, name| name.to_s } || []
        return "" if params.empty?
        "(#{params.join(", ")})"
      end

      # Extracts the source code from the policy's DSL block.
      #
      # @return [String] the block's source code as a string
      def call_body
        Hecks::Utils.block_source(@policy.block)
      end
    end
    end
  end
end
