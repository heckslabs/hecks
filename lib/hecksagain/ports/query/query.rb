module Hecksagain
  module Ports
    # Common query execution boundary. Adapters expose one optional native
    # hook; all other query behavior remains in the shared interpreter.
    module Query
      class Unsupported < StandardError; end

      module InMemory
        module_function

        def execute(records, declared, args = {})
          matched = records.select do |record|
            declared.wheres.all? { |clause| holds?(clause, comparable(record[clause.field]), args) }
          end
          if declared.order_by
            field = declared.order_by.field.to_sym
            matched = QuerySpecification::Common::NullPolicy.order(matched, direction: declared.order_by.direction,
                                                policy: declared.null_semantics) { |record| comparable(record[field]) }
          end
          matched = matched.first(resolve(declared.limit.value, args).to_i) if declared.limit
          matched = matched.drop(resolve(declared.offset.value, args).to_i) if declared.offset
          matched
        end

        def holds?(clause, held, args)
          want = comparable(resolve(clause.value, args))
          case clause.op.to_s
          when "lt" then held.is_a?(Numeric) && want.is_a?(Numeric) && held < want
          when "lte" then held.is_a?(Numeric) && want.is_a?(Numeric) && held <= want
          when "gt" then held.is_a?(Numeric) && want.is_a?(Numeric) && held > want
          when "gte" then held.is_a?(Numeric) && want.is_a?(Numeric) && held >= want
          when "ne" then held != want
          else held == want
          end
        end

        def resolve(value, args) = value.is_a?(Symbol) ? args[value] : value

        def comparable(value)
          value = value.to_h if value.is_a?(Runtime::Value)
          if value.is_a?(Hash)
            numeric = value.values.find { |field| field.is_a?(Numeric) }
            return numeric if numeric
            return value.values.first if value.size == 1
          end
          value
        end
      end

      module_function

      def execute(repository, specification, args = {}, context: {})
        adapter = repository.respond_to?(:adapter) ? repository.adapter : repository
        return nil unless adapter.respond_to?(:query)

        validate!(specification, adapter)
        adapter.query(specification, args, context: context)
      end

      def validate!(specification, adapter)
        if specification.cursor && specification.offset
          raise Unsupported, "a query cannot combine cursor and offset pagination"
        end

        return if specification.inspection.nil? || adapter.respond_to?(:inspect_query)
        return if specification.inspection.mode.to_s == "sql" && adapter.respond_to?(:query)

        raise Unsupported, "#{adapter.class} cannot inspect generated queries"
      end
    end
  end
end
