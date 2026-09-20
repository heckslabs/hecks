module Hecks
  module Adapters
    class Sqlite
      # The read path: `find`/`all`/`count` — split out of the `Sqlite`
      # class body only to keep it under its line budget; every method
      # here stays public/private on `Sqlite` instances exactly as if it
      # were still defined there.
      module Reads
        # Reads the current row for one aggregate identity.
        #
        # @param id [String, Object] the aggregate identity, bound as `id.to_s`
        # @return [Runtime::Instance, nil] the decoded record, or nil when no row has that id
        # @raise [SQLite3::Exception] if the statement fails
        def find(id)
          row = @db.get_first_row("SELECT * FROM #{quoted_table} WHERE id = ?", [id.to_s])
          return nil unless row

          Runtime::Instance.new(aggregate: @aggregate, id: row["id"], state: decode(row))
        end

        # Lists every stored record, ordered by id unless an ordering attribute is given.
        #
        # order_by is a runtime value — see postgres.rb's own all for the
        # full reasoning; whitelisted the identical way before it ever
        # reaches order_expression.
        #
        # @param order_by [String, Symbol, nil] attribute (or dotted value-object path) to sort
        #   by; nil orders by id alone
        # @param direction [Symbol, String] `:asc` or `:desc`, case-insensitive; anything else
        #   sorts ascending
        # @return [Array<Runtime::Instance>] the decoded records, `[]` when the table is empty
        # @raise [Runtime::WiringError] if `order_by` names no attribute of the aggregate
        # @raise [SQLite3::Exception] if the statement fails
        def all(order_by: nil, direction: :asc)
          @db.execute("SELECT * FROM #{quoted_table} #{order_sql_for(order_by, direction)}").map do |row|
            Runtime::Instance.new(aggregate: @aggregate, id: row["id"], state: decode(row))
          end
        end

        # Counts the rows in the aggregate's table, deleted records excluded.
        #
        # @return [Integer] number of current records
        # @raise [SQLite3::Exception] if the statement fails
        def count = @db.get_first_value("SELECT COUNT(*) FROM #{quoted_table}").to_i

        private

        def order_sql_for(order_by, direction)
          return "ORDER BY id" unless order_by

          name = order_by.to_s.split(".").first
          unless @aggregate.lifecycle&.field.to_s == name || @aggregate.attribute(name)
            raise Runtime::WiringError,
                  "#{@aggregate.name} has no attribute #{order_by.inspect} to order by"
          end

          spec = QuerySpecification::Common::OrderBy.new(field: order_by, direction: direction)
          "ORDER BY #{order_clause(spec, nil)}"
        end
      end
    end
  end
end
