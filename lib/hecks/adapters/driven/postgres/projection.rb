require "json"
require_relative "../projection/read_model_walk"

# The subclass needs its parent — and postgres.rb requires this file at
# its bottom, after class Postgres is defined, so the require cycle this
# creates resolves correctly from either entry point.
require_relative "../postgres"

module Hecks
  module Adapters
    # A Postgres read store rebuilt from the authoritative journal, entry by entry, answering a
    # rooted read model from its own tables (ADR 0121). Its world names its own `database` and
    # `schema`, apart from the authoritative store's.
    class PostgresProjection < Postgres
      include Projection::ReadModelWalk

      private

      def projected_row(aggregate, id)
        result = pg_exec_params("SELECT * FROM #{quote_ident(aggregate.storage_name)} WHERE id = $1", [id])
        result.ntuples.zero? ? nil : result[0]
      end

      # A reference column holds the id, so it compares directly against itself.
      def related_rows(aggregate, matches)
        clauses = matches.each_with_index.map { |(attribute, _id), index| "#{quote_ident(attribute.name)} = $#{index + 1}" }
        bind = matches.map { |_attribute, id| id }
        # Byte order, as the in-process loop sorts ids, whatever the database's collation.
        sql = "SELECT * FROM #{quote_ident(aggregate.storage_name)} WHERE #{clauses.join(" OR ")} ORDER BY id COLLATE \"C\""
        pg_exec_params(sql, bind).to_a
      end

      # `pg` answers every column as text: a list or value object parses from JSON, a declared
      # number coerces back (see Codec#coerce_scalar), and anything else reads as stored.
      def decode_column(aggregate, attribute, raw)
        return raw if attribute.nil?
        return (raw ? JSON.parse(raw) : nil) if json_column?(aggregate, attribute)

        coerce_scalar(attribute, raw)
      end
    end
  end
end
