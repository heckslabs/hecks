module Hecks
  module Adapters
    class Postgres
      # Postgres's spellings for the shared {SetTransform} statement (ADR 0129).
      module SetDialect
        # The type each placeholder is cast to, so Postgres never has to guess one.
        PLACEHOLDER_TYPES = { integer: "bigint", float: "double precision", string: "text", json: "jsonb" }.freeze

        # The cast that reads a JSON member back as the type Ruby holds it as.
        READ_CASTS = { integer: "::bigint", float: "::double precision", string: "" }.freeze

        # @return [String] the dialect the operator ledger's renderings name
        def set_transform_dialect = "postgres"

        private

        def typed_placeholder(binds, value, type)
          binds << value
          "$#{binds.size}::#{PLACEHOLDER_TYPES.fetch(type)}"
        end

        def null_safe_equality(left, right, negated:) = "(#{left} IS #{"NOT " unless negated}DISTINCT FROM #{right})"

        # The C collation compares by bytes, as Ruby compares Strings; the database's own may not.
        def text_ordering(sql) = "(#{sql}) COLLATE \"C\""

        # Postgres refuses an overflowing bigint itself, which rolls the statement back.
        def integer_guard(_sql) = nil

        def scalar_read(column, member, type) = "(#{quote_ident(column)} ->> #{text_literal(member)})#{READ_CASTS.fetch(type)}"

        def scalar_write(member, sql) = "jsonb_build_object(#{text_literal(member)}, #{sql})"

        def version_bump = ["hecks_version = #{quoted_table}.hecks_version + 1"]

        def run_set_transform(sql, binds)
          pg_exec_params(sql, binds).map { |row| instance_from_row(row) }
        rescue PG::Error => e
          raise SetTransform::Declined, "Postgres refused the set transform: #{e.message}"
        end
      end
    end
  end
end
