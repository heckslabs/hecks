module Hecks
  module Ports
    # Query execution boundary: an adapter may expose one native `query` hook, and everything
    # else runs in the shared interpreter (`query/ordering.rb`, `query/in_memory.rb`).
    module Query
      # A declared query the chosen adapter cannot honour as written.
      class Unsupported < StandardError; end

      module_function

      # Runs a declared query through the adapter's own `query` hook, if it has one.
      #
      # nil means "no native engine here" and the caller falls back to `InMemory.execute`; no
      # rows is `[]`.
      #
      # @param repository [Persistence::AppendOnly, Object] a repository, or a bare adapter
      # @param specification [QuerySpecification::Common::Options] the declared query
      # @param args [Hash{Symbol => Object}] values for Symbol-valued wheres, limit and offset
      # @param context [Hash{Symbol => Object}] passed to the adapter: `domain:`, `aggregate:`,
      #   and `registry:` where a comparator needs one
      # @return [Array<Runtime::Instance>, nil] matches, or nil if the adapter has no `query`
      # @raise [Ports::Query::Unsupported] see `validate!`
      def execute(repository, specification, args = {}, context: {})
        adapter = repository.respond_to?(:adapter) ? repository.adapter : repository
        return nil unless adapter.respond_to?(:query)

        validate!(specification, adapter)
        adapter.query(specification, args, context: context)
      end

      # Refuses cursor with offset pagination, and inspection the adapter cannot provide (`"sql"`
      # mode needs only a native `query`, other modes an `inspect_query` method).
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
