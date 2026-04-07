module Hecks
  module Generators
    module Domain
    # Hecks::Generators::Domain::LifecycleGenerator
    #
    # Generates a Lifecycle class for an aggregate's state machine. The lifecycle
    # encodes the field that holds state, the default state, valid states, and
    # transitions between states triggered by commands.
    #
    # The generated class includes:
    # - +FIELD+ -- the attribute name that holds the state (e.g., +:status+)
    # - +DEFAULT+ -- the initial state value (e.g., "draft")
    # - +STATES+ -- array of all valid state strings
    # - +TRANSITIONS+ -- hash mapping command names to target states (with optional +from+ guards)
    # - A +call(current_state, command_name)+ method that resolves the target state
    # - State predicate methods for each state (e.g., +active?+, +archived?+)
    #
    # == Usage
    #
    #   gen = LifecycleGenerator.new(lifecycle, domain_module: "ModelRegistryDomain", aggregate_name: "AiModel")
    #   gen.generate
    #
    class LifecycleGenerator

      # Initializes the lifecycle generator.
      #
      # @param lifecycle [Object] the lifecycle model object; provides +field+, +default+,
      #   +states+, and +transitions+
      # @param domain_module [String] the Ruby module name to wrap the generated class in
      # @param aggregate_name [String] the name of the parent aggregate class
      def initialize(lifecycle, domain_module:, aggregate_name:)
        @lifecycle = lifecycle
        @domain_module = domain_module
        @aggregate_name = aggregate_name
      end

      # Generates the full Ruby source code for the Lifecycle class.
      #
      # Produces a class nested under the aggregate with constants for field,
      # default state, valid states, and transitions. Includes a +call+ method
      # for resolving state transitions and predicate methods for each state.
      #
      # @return [String] the generated Ruby source code, newline-terminated
      def generate
        lines = []
        lines << "module #{@domain_module}"
        lines << "  class #{@aggregate_name}"
        lines << "    class Lifecycle"
        lines << "      FIELD = :#{@lifecycle.field} unless defined?(FIELD)"
        lines << "      DEFAULT = #{@lifecycle.default.inspect} unless defined?(DEFAULT)"
        lines << "      STATES = [#{@lifecycle.states.map(&:inspect).join(', ')}].freeze unless defined?(STATES)"
        lines << ""
        lines << "      TRANSITIONS = {"
        @lifecycle.transitions.each do |cmd_name, transition|
          if transition.respond_to?(:constrained?) && transition.constrained?
            lines << "        #{cmd_name.inspect} => { target: #{transition.target.inspect}, from: #{transition.from.inspect} },"
          else
            target = transition.respond_to?(:target) ? transition.target : transition.to_s
            lines << "        #{cmd_name.inspect} => #{target.inspect},"
          end
        end
        lines << "      }.freeze unless defined?(TRANSITIONS)"
        lines << ""
        lines << "      attr_reader :target"
        lines << ""
        lines << "      def call(current_state, command_name)"
        lines << "        entry = TRANSITIONS[command_name]"
        lines << "        @target = entry.is_a?(Hash) ? entry[:target] : entry"
        lines << "        @target ||= current_state"
        lines << "        self"
        lines << "      end"
        lines << ""
        @lifecycle.states.each do |state|
          lines << "      def #{state}?; @target == #{state.inspect}; end"
        end
        lines << "    end"
        lines << "  end"
        lines << "end"
        lines.join("\n") + "\n"
      end
    end
    end
  end
end
