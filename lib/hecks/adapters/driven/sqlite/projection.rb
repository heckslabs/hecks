require "json"
require_relative "../projection/read_model_walk"

# The subclass needs its parent — and sqlite.rb requires this file at
# its bottom, after class Sqlite is defined, so the require cycle this
# creates resolves correctly from either entry point.
require_relative "../sqlite"

module Hecks
  module Adapters
    # Rebuilds a read store from the authoritative journal, entry by entry.
    # Values are written as JSON, references as bare ids — the shapes the command path writes.
    class SqliteProjection < Sqlite
      include Projection::ReadModelWalk

      # Replaces or deletes the read store's row for one journal entry, encoding the entry's
      # state directly rather than through a `Runtime::Instance`.
      #
      # @param entry [Ports::Persistence::Entry] the save or delete to materialize
      # @return [Ports::Persistence::Entry, Array] the same `entry` for a save; for a delete,
      #   the `DELETE` statement's empty result rows
      # @raise [SQLite3::Exception] if the statement fails
      def project(entry)
        return @db.execute("DELETE FROM #{quoted_table} WHERE id = ?", [entry.id]) if entry.delete?

        columns = (["id"] + persisted_fields.map { |field| field[:name].to_s }).map { |column| quote_ident(column) }
        @db.execute(upsert_sql(columns), row_values(entry))
        entry
      end

      private

      def row_values(entry)
        [entry.id.to_s] + persisted_fields.map { |field| encode_field(field, entry.state[field[:name]]) }
      end

      def projected_row(aggregate, id)
        @db.get_first_row("SELECT * FROM #{quote_ident(aggregate.storage_name)} WHERE id = ?", [id])
      end

      # A reference column holds the id, so it compares directly against itself.
      def related_rows(aggregate, matches)
        clauses = matches.map { |attribute, _id| "#{quote_ident(attribute.name)} = ?" }
        bind = matches.map { |_attribute, id| id }
        @db.execute("SELECT * FROM #{quote_ident(aggregate.storage_name)} WHERE #{clauses.join(" OR ")} ORDER BY id", bind)
      end

      # A reference is a scalar id (see Codec#decode); a list or value object is JSON.
      def decode_column(aggregate, attribute, raw)
        return raw if attribute.nil? || !json_column?(aggregate, attribute)

        raw ? JSON.parse(raw) : nil
      end
    end
  end
end
