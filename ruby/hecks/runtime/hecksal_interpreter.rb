# Hecks::HecksalInterpreter
#
# @domain AcceptanceTest
#
# Interprets given/then declarations at runtime. Checks preconditions
# against aggregate state, applies declarative mutations. No Ruby in
# the domain — pure UL evaluated by the interpreter.
#
#   HecksalInterpreter.check_givens(pizza, command)
#   HecksalInterpreter.apply_mutations(pizza, command.mutations)
#
module Hecks
  module HecksalInterpreter
    # Check all given preconditions against the aggregate and command.
    #
    # @param aggregate [Object] the aggregate instance
    # @param command [Object] the command instance
    # @param givens [Array<Given>] precondition declarations
    # @raise [PreconditionError] if any given is false
    def self.check_givens(aggregate, command, givens)
      givens.each do |g|
        ctx = EvalContext.new(aggregate, command)
        unless ctx.evaluate(g.expression)
          msg = g.message || "Given failed: #{g.expression}"
          raise Hecks::PreconditionError, msg
        end
      end
    end

    # Apply all mutations to the aggregate.
    #
    # @param aggregate [Object] the aggregate instance
    # @param command [Object] the command instance (for resolving attribute refs)
    # @param mutations [Array<Mutation>] declarative state changes
    # @return [Object] the mutated aggregate
    def self.apply_mutations(aggregate, command, mutations)
      mutations.each do |m|
        case m.operation
        when :set
          aggregate.send(:"#{m.field}=", resolve_value(m.value, command))
        when :append
          collection = aggregate.send(m.field)
          collection = collection.to_a if collection.respond_to?(:to_a) && !collection.is_a?(Array)
          collection = [] if collection.nil?
          collection = collection.dup if collection.frozen?
          collection << resolve_value(m.value, command)
          aggregate.send(:"#{m.field}=", collection)
        when :increment
          current = aggregate.send(m.field) || 0
          aggregate.send(:"#{m.field}=", current + m.value)
        when :decrement
          current = aggregate.send(m.field) || 0
          aggregate.send(:"#{m.field}=", current - m.value)
        when :toggle
          current = aggregate.send(m.field)
          aggregate.send(:"#{m.field}=", current == "true" ? "false" : "true")
        end
      end
      aggregate
    end

    # Resolve a value — symbols reference command attributes, everything else is literal.
    def self.resolve_value(value, command)
      case value
      when Symbol
        command.respond_to?(value) ? command.send(value) : value
      when Hash
        value.transform_values { |v| resolve_value(v, command) }
      else
        value
      end
    end
    private_class_method :resolve_value

    # Evaluation context that has access to both aggregate and command state.
    class EvalContext
      def initialize(aggregate, command)
        @aggregate = aggregate
        @command = command
      end

      def evaluate(expression)
        instance_eval(expression)
      end

      def method_missing(name, *args)
        if @aggregate.respond_to?(name)
          @aggregate.send(name, *args)
        elsif @command.respond_to?(name)
          @command.send(name, *args)
        else
          super
        end
      end

      def respond_to_missing?(name, include_private = false)
        @aggregate.respond_to?(name) || @command.respond_to?(name) || super
      end
    end
  end
end
