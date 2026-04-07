module Hecks
  module DomainModel
    module Structure

    # Hecks::DomainModel::Structure::Scope
    #
    # Value object representing a named query scope declared on an aggregate.
    # A scope has a name and conditions -- either a plain Hash for simple
    # equality filters, or a Proc/lambda for parameterized queries. Use
    # +callable?+ to distinguish the two forms.
    #
    # Scopes are used at runtime by the query subsystem to filter collections
    # of aggregates. Static (Hash) scopes apply fixed equality conditions, while
    # callable (Proc) scopes accept parameters and return a conditions Hash.
    #
    # Part of the DomainModel IR layer. Built by AggregateBuilder and consumed
    # by generators and the querying subsystem at runtime.
    #
    #   # Static scope -- fixed conditions
    #   Scope.new(name: :active, conditions: { status: "active" })
    #
    #   # Callable scope -- parameterized conditions
    #   Scope.new(name: :by_name, conditions: ->(name) { { name: name } })
    #
    class Scope
      # @return [Symbol] the scope name, used as a method name on the query interface
      #   (e.g., :active, :by_name, :recent)
      attr_reader :name

      # @return [Hash, Proc] the filtering conditions. A Hash for static equality filters
      #   (e.g., +{ status: "active" }+) or a Proc/lambda that accepts parameters and
      #   returns a conditions Hash (e.g., +->(name) { { name: name } }+).
      attr_reader :conditions

      # Creates a new Scope.
      #
      # @param name [Symbol] the scope name, used as a method name on the query interface
      # @param conditions [Hash, Proc] the filtering conditions. Pass a Hash for simple
      #   equality filters, or a Proc/lambda for parameterized scopes that accept arguments
      #   and return a conditions Hash.
      #
      # @return [Scope] a new Scope instance
      def initialize(name:, conditions:)
        @name = name
        @conditions = conditions
      end

      # Returns whether this scope accepts parameters.
      # Callable scopes use a Proc/lambda for conditions and require arguments
      # at query time. Non-callable scopes use a static Hash.
      #
      # @return [Boolean] true if conditions is a Proc (parameterized scope),
      #   false if conditions is a Hash (static scope)
      def callable?
        conditions.is_a?(Proc)
      end
    end
    end
  end
end
