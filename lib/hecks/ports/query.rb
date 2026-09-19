module Hecks
  module Ports
    # Common query execution boundary. Adapters expose one optional native
    # hook; all other query behavior remains in the shared interpreter.
    # Ordering (the meaning of an ask's answer order) and InMemory (the
    # fallback engine for stores with no query engine of their own) are
    # its collaborators — query/ordering.rb and query/in_memory.rb.
    module Query
      class Unsupported < StandardError; end

      module_function

      # Runs a query through a repository's native adapter, if it has one.
      #
      # @param repository [Object] the repository (or bare adapter) to query
      # @param specification [Object] the query specification to run
      # @param args [Hash] arguments the specification's predicates read
      # @param context [Hash] execution context passed through to the adapter
      # @return [Object, nil] the adapter's own query result, or nil if it has no native `query`
      # @raise [Unsupported] if the specification isn't one this adapter can run or inspect
      def execute(repository, specification, args = {}, context: {})
        adapter = repository.respond_to?(:adapter) ? repository.adapter : repository
        return nil unless adapter.respond_to?(:query)

        validate!(specification, adapter)
        adapter.query(specification, args, context: context)
      end

      # @param specification [Object] the query specification to validate
      # @param adapter [Object] the adapter that would run it
      # @return [void]
      # @raise [Unsupported] if the specification combines cursor and offset pagination, or
      #   asks for inspection the adapter cannot provide
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
