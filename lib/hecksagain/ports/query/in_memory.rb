require_relative "ordering"
require_relative "../../runtime/value"

module Hecksagain
  module Ports
    module Query
      module InMemory
        module_function

        def execute(records, declared, args = {})
          matched = records.select do |record|
            declared.wheres.all? { |clause| holds?(clause, comparable(record[clause.field]), args) }
          end
          field   = declared.order_by&.field&.to_sym
          matched = Ordering.apply(matched, declared.order_by, declared.null_semantics,
                                   identity: ->(record) { record.id.to_s }) { |record| comparable(record[field]) }
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
          when "contains" then members(held).include?(want.to_s)
          else                 held == want
          end
        end

        def ordered?(held, want) = held.is_a?(Numeric) && want.is_a?(Numeric)

        # A list of value objects is a list of single-field hashes — unwrap
        # each element the same way a scalar field is, before stringifying.
        def members(value)
          return value.map { |element| comparable(element).to_s } if value.is_a?(Array)

          value.to_s.split(",").map(&:strip)
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
