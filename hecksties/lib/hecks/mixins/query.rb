  # Hecks::Query
  #
  # Mixin for generated query classes. Provides repository wiring and
  # delegates query methods (where, order, limit, etc.) to a QueryBuilder.
  # The generated call method is pure domain logic -- describes the query.
  #
  # == How it works
  #
  # When +.call+ is invoked, a new query instance is created and a +QueryBuilder+
  # is initialized against the wired repository. The user-defined +#call+ method
  # uses DSL methods (+where+, +order+, +limit+, +offset+) to build the query.
  # The resulting +QueryBuilder+ is chainable and lazily evaluated.
  #
  # == Comparison operators
  #
  # For range and inequality queries, use the operator helpers inside +#call+:
  # +gt+, +gte+, +lt+, +lte+, +not_eq+, +one_of+. These return operator
  # objects that the QueryBuilder interprets.
  #
  # == Usage
  #
  #   class Classics
  #     include Hecks::Query
  #
  #     def call
  #       where(style: "Classic").order(:name)
  #     end
  #   end
  #
  #   Classics.call          # => QueryBuilder (chainable)
  #   Classics.call.to_a     # => [#<Pizza>, ...]
  #
module Hecks
  module Query
    # Hook called when a class includes +Hecks::Query+. Extends the class
    # with +ClassMethods+ for repository wiring.
    #
    # @param base [Class] the class including this module
    # @return [void]
    def self.included(base)
      base.extend(ClassMethods)
    end

    # Class-level DSL for query classes. Provides the repository accessor
    # (wired during boot) and the +.call+ entry point.
    module ClassMethods
      # @!attribute [rw] repository
      #   The repository to query against, wired by the Hecks runtime during boot.
      #   @return [Object] a repository instance (memory adapter, SQL adapter, etc.)
      attr_accessor :repository

      # Instantiates the query and executes it against the repository.
      # Creates a +QueryBuilder+ bound to the repository, then invokes the
      # user-defined +#call+ method which uses DSL methods to build the query.
      #
      # @param args [Array] positional arguments forwarded to the user-defined +#call+
      # @return [Querying::QueryBuilder] the constructed query (chainable, call +.to_a+ to materialize)
      def call(*args)
        instance = new
        instance.send(:with_builder, *args)
      end
    end

    private

    # Initializes a QueryBuilder for the repository and invokes the user-defined
    # +#call+ method. If +#call+ returns a QueryBuilder, that is returned directly;
    # otherwise the internally tracked builder is returned.
    #
    # @param args [Array] positional arguments forwarded to +#call+
    # @return [Querying::QueryBuilder]
    def with_builder(*args)
      @builder = Querying::QueryBuilder.new(self.class.repository)
      result = call(*args)
      result.is_a?(Querying::QueryBuilder) ? result : @builder
    end

    # Adds a where clause to the query. Conditions are ANDed together.
    #
    # @param conditions [Hash{Symbol => Object}] attribute-value pairs to filter by;
    #   values can be plain objects for equality or operator objects (+gt+, +lt+, etc.)
    # @return [Querying::QueryBuilder] the updated query builder
    def where(**conditions)
      @builder = @builder.where(**conditions)
    end

    # Adds an order clause to the query.
    #
    # @param key [Symbol] the attribute to sort by
    # @return [Querying::QueryBuilder] the updated query builder
    def order(key)
      @builder = @builder.order(key)
    end

    # Limits the number of results returned.
    #
    # @param n [Integer] maximum number of results
    # @return [Querying::QueryBuilder] the updated query builder
    def limit(n)
      @builder = @builder.limit(n)
    end

    # Skips the first N results (for pagination).
    #
    # @param n [Integer] number of results to skip
    # @return [Querying::QueryBuilder] the updated query builder
    def offset(n)
      @builder = @builder.offset(n)
    end

    # Returns a greater-than operator for use in +where+ conditions.
    #
    # @param value [Comparable] the threshold value
    # @return [Querying::Operators::Gt]
    def gt(value)     = Querying::Operators::Gt.new(value)

    # Returns a greater-than-or-equal operator for use in +where+ conditions.
    #
    # @param value [Comparable] the threshold value
    # @return [Querying::Operators::Gte]
    def gte(value)    = Querying::Operators::Gte.new(value)

    # Returns a less-than operator for use in +where+ conditions.
    #
    # @param value [Comparable] the threshold value
    # @return [Querying::Operators::Lt]
    def lt(value)     = Querying::Operators::Lt.new(value)

    # Returns a less-than-or-equal operator for use in +where+ conditions.
    #
    # @param value [Comparable] the threshold value
    # @return [Querying::Operators::Lte]
    def lte(value)    = Querying::Operators::Lte.new(value)

    # Returns a not-equal operator for use in +where+ conditions.
    #
    # @param value [Object] the value to exclude
    # @return [Querying::Operators::NotEq]
    def not_eq(value) = Querying::Operators::NotEq.new(value)

    # Returns an inclusion operator for use in +where+ conditions.
    # Matches any value in the given collection.
    #
    # @param values [Array] the set of acceptable values
    # @return [Querying::Operators::In]
    def one_of(values) = Querying::Operators::In.new(values)
  end
end
