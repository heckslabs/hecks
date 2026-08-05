require_relative "ordering"
require_relative "../../runtime/value"
require_relative "../../query_specification/field_path"

module Hecksagain
  module Ports
    module Query
      module InMemory
        FieldPath = QuerySpecification::FieldPath

        module_function

        def execute(records, declared, args = {})
          matched = records.select do |record|
            declared.wheres.all? { |clause| holds?(clause, comparable(FieldPath.dig(record, clause.field)), args) }
          end
          field   = declared.order_by&.field
          matched = Ordering.apply(matched, declared.order_by, declared.null_semantics,
                                   identity: ->(record) { record.id.to_s }) { |record| comparable(FieldPath.dig(record, field)) }
          matched = matched.first(resolve(declared.limit.value, args).to_i) if declared.limit
          matched = matched.drop(resolve(declared.offset.value, args).to_i) if declared.offset
          matched
        end

        # The same 8 comparators QuerySpecification::Common::COMPARATORS
        # declares. This is the path that actually runs for a memory- or
        # heki-backed aggregate query ; QueryInterpreter#holds? only runs for
        # entity/sub-list queries, or when no adapter implements :query at all.
        def holds?(clause, held, args)
          want = comparable(resolve(clause.value, args))

          case clause.op.to_s
          when "eq"       then held == want
          when "ne"       then held != want
          when "lt"       then ordered?(held, want) && held < want
          when "lte"      then ordered?(held, want) && held <= want
          when "gt"       then ordered?(held, want) && held > want
          when "gte"      then ordered?(held, want) && held >= want
          when "in"       then members(want).include?(held.to_s)
          when "contains" then contains?(held, want)
          else                 held == want
          end
        end

        def ordered?(held, want) = held.is_a?(Numeric) && want.is_a?(Numeric)

        # A list of value objects is a list of single-field hashes — unwrap
        # each element the same way a scalar field is, before stringifying.
        # This is `in`'s own reading of ITS ARGUMENT (a caller may legitimately
        # pass "a,b,c" meaning "any of these") — unrelated to `contains`,
        # which reads the STORED field and never splits it this way. See
        # `contains?`.
        def members(value)
          return value.map { |element| comparable(element).to_s } if value.is_a?(Array)

          value.to_s.split(",").map(&:strip)
        end

        # `contains` means two different things depending on what is HELD —
        # real ELEMENT membership for a `list_of` field (a genuine Array
        # arrives already, one element one member, nothing to split), and
        # plain SUBSTRING for anything else. It used to fall through to
        # `members`' comma-split for the scalar case too, silently reading a
        # free-text field's own comma as a separator — which the SQL side's
        # `instr`/`position` never did, so the two disagreed the moment a
        # scalar's real content held a comma. Matching SQL's substring
        # reading here, rather than the other way around, keeps every
        # engine (Memory, Heki, Sqlite, Postgres, the reference interpreter)
        # answering `contains` identically for the same declared field.
        def contains?(held, want)
          return members(held).include?(want.to_s) if held.is_a?(Array)

          held.to_s.include?(want.to_s)
        end

        def resolve(value, args) = value.is_a?(Symbol) ? args[value] : value

        def comparable(value)
          value = value.to_h if value.is_a?(Runtime::Value)
          return value unless value.is_a?(Hash)

          numeric = value.values.find { |field| field.is_a?(Numeric) }
          return numeric if numeric
          return value.values.first if value.size == 1

          value
        end
      end
    end
  end
end
