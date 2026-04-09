# Hecks::Runtime::Projection
#
# In-memory CQRS read model projection. Maintains a hash of
# aggregate_id to row data, updated by event handlers and
# queryable via named queries. Thread-safe via Mutex.
#
#   proj = Projection.new(
#     event_handlers: { "CreatedPizza" => ->(event) { ... } },
#     queries: { "Popular" => ->(data) { ... } }
#   )
#   proj.apply(event)
#   proj.query("Popular")  # => matching rows
#
module Hecks
  class Runtime
    class Projection
      # @param event_handlers [Hash{String => Proc}] event name to handler proc
      # @param queries [Hash{String => Proc}] query name to filter proc
      def initialize(event_handlers:, queries:)
        @event_handlers = event_handlers
        @queries = queries
        @data = {}
        @mutex = Mutex.new
      end

      # Apply a domain event to this projection via its registered handler.
      # The handler block is evaluated in the context of this projection
      # instance, giving it access to upsert/update/delete.
      #
      # @param event [Object] the domain event
      # @return [void]
      def apply(event)
        event_name = Hecks::Utils.const_short_name(event)
        handler = @event_handlers[event_name]
        return unless handler

        @mutex.synchronize do
          instance_exec(event, &handler)
        end
      end

      # Create or merge a row by aggregate ID.
      #
      # @param id [String] the aggregate ID
      # @param attrs [Hash] attributes to merge into the row
      # @return [void]
      def upsert(id, attrs)
        @data[id] = (@data[id] || {}).merge(attrs)
      end

      # Modify an existing row by aggregate ID.
      #
      # @param id [String] the aggregate ID
      # @yield [row] block receives the current row hash for mutation
      # @return [void]
      def update(id, &block)
        row = @data[id]
        return unless row

        block.call(row)
      end

      # Delete a row by aggregate ID.
      #
      # @param id [String] the aggregate ID
      # @return [void]
      def delete(id)
        @data.delete(id)
      end

      # Return all rows as an array of [id, row] pairs.
      #
      # @return [Array<Array(String, Hash)>]
      def all
        @mutex.synchronize { @data.dup }
      end

      # Find a single row by aggregate ID.
      #
      # @param id [String] the aggregate ID
      # @return [Hash, nil] the row hash or nil
      def find(id)
        @mutex.synchronize { @data[id]&.dup }
      end

      # Run a named query, returning matching rows.
      # The query block is evaluated in the context of this projection
      # instance, giving it access to the select helper.
      #
      # @param name [String] the query name
      # @return [Array<Array(String, Hash)>] matching [id, row] pairs
      def query(name)
        query_block = @queries[name.to_s]
        return [] unless query_block

        @mutex.synchronize do
          instance_exec(&query_block)
        end
      end

      # Filter rows by a predicate block. Used inside query blocks.
      #
      # @yield [id, row] predicate block
      # @return [Array<Array(String, Hash)>]
      def select(&block)
        @data.select(&block).to_a
      end
    end
  end
end
