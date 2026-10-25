require_relative "../bluebook/expression"
require_relative "../runtime/value"

module Hecks
  module Bulk
    # The arguments a bulk run's command carries for one row when it runs as one statement
    # (ADR 0128): the row's key, then every declared default, each coerced as a dispatch coerces
    # it, so an event's payload is the one a row-by-row dispatch would emit.
    class SetArguments
      # Stands for the row's key among the scalars: its value differs per row, so no expression
      # that reads it compiles.
      PER_ROW = Object.new.freeze

      # @param aggregate [Bluebook::Aggregate] the aggregate the command acts on
      # @param command [Class] the command
      # @param key [Symbol] the argument a row's id fills
      def initialize(aggregate, command, key)
        @aggregate = aggregate
        @command = command
        @key = key.to_sym
        @defaults = coerced(command.attributes.reject { |attribute| attribute.default.nil? })
      end

      # @param id [Object] a row's identity
      # @return [Hash{Symbol => Object}] the arguments that row's dispatch carries
      def for_row(id) = { @key => id }.merge(@defaults)

      # Every argument as the plain scalar an expression reads, the key as {PER_ROW}.
      #
      # @return [Hash{Symbol => Object}]
      def scalars
        @defaults.transform_values { |value| Bluebook::Expression::Resolver.unwrap_scalar(value) }.merge(@key => PER_ROW)
      end

      # What a `sets` source resolves to: an argument's value for a Symbol, the literal itself
      # otherwise.
      #
      # @param source [Symbol, Object] the mutation's source
      # @return [Object] the value every row takes
      # @raise [Runtime::TypeMismatch] if the source is the row's key, which differs per row
      def source_value(source)
        raise Runtime::TypeMismatch, "the row's key #{@key} differs per row" if source == @key

        source.is_a?(Symbol) ? @defaults[source] : source
      end

      # The signed Integer an increment or decrement adds.
      #
      # @param mutation [Bluebook::Mutation] an `increment` or `decrement`
      # @return [Integer] the amount, negative for a decrement
      # @raise [Runtime::TypeMismatch] if the amount is not an Integer
      def step(mutation)
        amount = Bluebook::Expression::Resolver.unwrap_scalar(source_value(mutation.source))
        raise Runtime::TypeMismatch, "#{mutation.target} steps by #{amount.inspect}" unless amount.is_a?(Integer)

        mutation.op == :decrement ? -amount : amount
      end

      private

      def coerced(attributes)
        attributes.to_h do |attribute|
          [attribute.name.to_sym, Runtime::Value.for_attribute(@aggregate, attribute, attribute.default, argument: true)]
        end
      end
    end
  end
end
