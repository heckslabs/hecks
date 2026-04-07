module Hecks
  module DomainModel
    module Behavior

    # Hecks::DomainModel::Behavior::Query
    #
    # Intermediate representation of a domain query -- a named, reusable lookup
    # defined in the DSL. Each query has a name and a block that uses the
    # query DSL (where, order, limit, etc.) to build results.
    #
    # At runtime, queries are executed against the repository via QueryBuilder,
    # which evaluates the block in a context that supports filtering, ordering,
    # and pagination methods.
    #
    # Part of the DomainModel IR layer. Built by the DSL aggregate builder and
    # consumed by QueryGenerator to produce query classes in the domain gem.
    #
    #   query = Query.new(name: "Classics", block: proc { where(style: "Classic") })
    #   query.name   # => "Classics"
    #   query.block  # => #<Proc>
    #
    class Query
      # @return [String] PascalCase query name (e.g. "Classics", "RecentOrders")
      # @return [Proc] block evaluated in the query DSL context at runtime;
      #   can call +where+, +order+, +limit+, and other query methods
      attr_reader :name, :block

      # Creates a new Query IR node.
      #
      # @param name [String] PascalCase query name (e.g. "Classics")
      # @param block [Proc] callable that defines the query logic. Evaluated in
      #   a QueryBuilder context at runtime, with access to methods like +where+,
      #   +order+, +limit+, etc.
      # @return [Query]
      def initialize(name:, block:)
        @name = name
        @block = block
      end
    end
    end
  end
end
