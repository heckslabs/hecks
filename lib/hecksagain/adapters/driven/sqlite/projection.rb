require_relative "../../../runtime/instance"
require_relative "../../../runtime/value"
require_relative "../../../ports/query/in_memory"

# The subclass needs its parent — and sqlite.rb requires this file at
# its BOTTOM, after class Sqlite is defined, so the require cycle this
# creates resolves correctly from either entry point.
require_relative "../sqlite"

module Hecksagain
  module Adapters
    # Rebuilds a read store from the authoritative journal, entry by entry.
    # A value object is written as its JSON object and a reference as the
    # bare id it holds — the same shapes the command path writes, so there
    # is no second representation to accept here any more.
    class SqliteProjection < Sqlite
      def project(entry)
        return @db.execute("DELETE FROM #{quoted_table} WHERE id = ?", [entry.id]) if entry.delete?

        columns = (["id"] + persisted_fields.map { |field| field[:name].to_s }).map { |column| quote_ident(column) }
        values  = [entry.id.to_s] + persisted_fields.map { |field| encode_field(field, entry.state[field[:name]]) }
        @db.execute("INSERT OR REPLACE INTO #{quoted_table} (#{columns.join(', ')}) VALUES (#{Array.new(columns.size, '?').join(', ')})", values)
        entry
      end

      # Execute a declared read model against the projected aggregate-head
      # tables. The report shape is assembled from SQL-selected rows, rather
      # than scanning repositories and matching references in Ruby.
      def query_read_model(_domain, model, args, bluebook = nil)
        raise ArgumentError, "projection query needs its domain bluebook" unless bluebook

        # The REFERENCE's own shape, read the same way ReadModelInterpreter
        # reads it — not the identity unwrap, which is gone : an identity is
        # declared as a path and followed.
        reference_id = args.fetch(model.reference_name).to_s
        eligible = model.filtered_head_name
        reports = {}
        model.aggregate_heads.each do |head|
          aggregate = bluebook.aggregate(head[:aggregate])
          rows = if head[:aggregate] == model.reference_target
                   [select_projected(aggregate, reference_id)].compact
                 else
                   select_related(aggregate, model.reference_target, reference_id)
                 end
          rows = Ports::Query::InMemory.execute(rows, model, args) if head[:as] == eligible
          reports[head[:as]] = if head[:many]
                                 rows.map { |row| Runtime::Value.materialize(row.to_h) }
                               else
                                 rows.first && Runtime::Value.materialize(rows.first.to_h)
                               end
        end
        [reports]
      end

      private

      def select_projected(aggregate, id)
        row = @db.get_first_row("SELECT * FROM #{quote_ident(aggregate.storage_name)} WHERE id = ?", [id.to_s])
        row && projected_instance(aggregate, row)
      end

      def select_related(aggregate, target, id)
        references = aggregate.attributes.select do |attribute|
          attribute.reference? && attribute.type.target_name == target.to_s
        end
        return [] if references.empty?

        # A REFERENCE COLUMN HOLDS THE ID, so it compares as itself. The
        # `json_extract(col,'$.value') = ? OR col = ?` this replaced was
        # reading both shapes because both existed — one written by the
        # command path, one by older journals. There is one shape now.
        clauses = references.map { |attribute| "#{quote_ident(attribute.name)} = ?" }
        bind = references.map { id.to_s }
        @db.execute("SELECT * FROM #{quote_ident(aggregate.storage_name)} WHERE #{clauses.join(' OR ')} ORDER BY id", bind)
           .map { |row| projected_instance(aggregate, row) }
      end

      def projected_instance(aggregate, row)
        Runtime::Instance.new(aggregate: aggregate, id: row["id"], state: decode_for(aggregate, row))
      end

      def decode_for(aggregate, row)
        fields = aggregate.attributes.map { |attribute| [attribute.name, attribute] }
        if (lifecycle = aggregate.lifecycle) && !fields.any? { |name, _| name == lifecycle.field }
          fields << [lifecycle.field, nil]
        end
        fields.each_with_object({}) do |(name, attribute), state|
          raw = row[name.to_s]
          state[name] =
            if attribute.nil?
              raw
            elsif attribute.list? || !aggregate.value_object(attribute.type).nil?
              raw ? JSON.parse(raw, symbolize_names: true) : nil
            else
              # A reference is a scalar id — see Codec#decode.
              raw
            end
        end
      end
    end
  end
end
