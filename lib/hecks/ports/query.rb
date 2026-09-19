module Hecks
  module Ports
    # Common query execution boundary. Adapters expose one optional native
    # hook; all other query behavior remains in the shared interpreter.
    # Ordering (the meaning of an ask's answer order) and InMemory (the
    # fallback engine for stores with no query engine of their own) are
    # its collaborators — query/ordering.rb and query/in_memory.rb.
    module Query
      # A declared query the chosen adapter cannot honour as written — refused
      # by `validate!` before the adapter runs it.
      class Unsupported < StandardError; end

      module_function

      # Runs a declared query through the adapter's own `query` hook, if it has one.
      #
      # A nil answer means "no native engine here", and the caller falls back to the shared
      # interpreter or to `InMemory.execute`; it never means "no rows", which is `[]`.
      #
      # @param repository [Persistence::AppendOnly, Object] the repository whose `adapter` is
      #   asked, or a bare persistence adapter (anything that does not answer `adapter`)
      # @param specification [QuerySpecification::Common::Options] the declared query: a
      #   `Bluebook::Query`, a read-model specification, or a delegator wrapping one
      # @param args [Hash{Symbol => Object}] the caller's arguments, which a where-clause,
      #   limit or offset written as a Symbol reads its value from
      # @param context [Hash{Symbol => Object}] passed through to the adapter: `domain:`,
      #   `aggregate:` and, where a comparator needs one, `registry:`
      # @return [Array<Runtime::Instance>, nil] the matching records, filtered, ordered and
      #   paged by the adapter (`[]` when none match); nil if the adapter has no `query`
      #   method
      # @raise [Ports::Query::Unsupported] if the specification combines cursor and offset
      #   pagination, or asks for inspection the adapter cannot provide
      # @raise [Runtime::WiringError] if a where-clause names an operation no comparator
      #   handles (raised by the in-memory engine behind `Memory`, `Heki` and the like)
      # @raise [ArgumentError] if a SQL-backed adapter cannot compile a where-clause's
      #   operator
      def execute(repository, specification, args = {}, context: {})
        adapter = repository.respond_to?(:adapter) ? repository.adapter : repository
        return nil unless adapter.respond_to?(:query)

        validate!(specification, adapter)
        adapter.query(specification, args, context: context)
      end

      # Refuses a specification the adapter about to run it cannot honour.
      #
      # Inspection is honoured by an adapter with an `inspect_query` method, or, for the
      # `"sql"` mode alone, by any adapter with a native `query`.
      #
      # @param specification [QuerySpecification::Common::Options] the declared query to check
      # @param adapter [Object] the persistence adapter that would run it; only what it
      #   responds to (`inspect_query`, `query`) is read
      # @return [void]
      # @raise [Ports::Query::Unsupported] if the specification declares both a cursor and
      #   an offset, or asks for inspection the adapter cannot provide
      def validate!(specification, adapter)
        raise Unsupported, "a query cannot combine cursor and offset pagination" if specification.cursor && specification.offset

        return if specification.inspection.nil? || adapter.respond_to?(:inspect_query)
        return if specification.inspection.mode.to_s == "sql" && adapter.respond_to?(:query)

        raise Unsupported, "#{adapter.class} cannot inspect generated queries"
      end
    end
  end
end

require_relative "query/ordering"
require_relative "query/in_memory"
