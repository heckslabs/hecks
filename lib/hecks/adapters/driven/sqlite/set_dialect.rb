module Hecks
  module Adapters
    class Sqlite
      # SQLite's spellings for the shared {SetTransform} statement (ADR 0129).
      module SetDialect
        # @return [String] the dialect the operator ledger's renderings name
        def set_transform_dialect = "sqlite"

        private

        # Numbered, so a guard can repeat an operand's text and still bind the same value.
        def typed_placeholder(binds, value, _type)
          binds << value
          "?#{binds.size}"
        end

        def null_safe_equality(left, right, negated:) = "(#{left} IS #{"NOT " if negated}#{right})"

        # SQLite compares text by bytes, as Ruby compares Strings.
        def text_ordering(sql) = sql

        # An integer result that overflowed comes back as a real, which Ruby would refuse.
        def integer_guard(sql) = "typeof(#{sql}) = 'integer'"

        def scalar_read(column, member, _type) = "json_extract(#{quote_ident(column)}, '$.#{member}')"

        def scalar_write(member, sql) = "json_object('#{member}', #{sql})"

        def version_bump = []

        def run_set_transform(sql, binds)
          @db.execute(sql, binds).map { |row| Runtime::Instance.new(aggregate: @aggregate, id: row["id"], state: decode(row)) }
        rescue SQLite3::Exception => e
          raise SetTransform::Declined, "SQLite refused the set transform: #{e.message}"
        end
      end
    end
  end
end
