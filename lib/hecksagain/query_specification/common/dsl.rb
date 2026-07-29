module Hecksagain
  module QuerySpecification
    module Common
      module DSL
        def where(clauses)
          @wheres ||= []
          clauses.each do |field, value|
            op, operand = split_comparator(value)
            @wheres << WhereClause.new(field: field, op: op, value: operand)
          end
        end

        def order_by(field, direction = :asc)
          @order_by = OrderBy.new(field: field, direction: direction)
        end

        def limit(value) = @limit = LimitSpec.new(value: value)
        def offset(value) = @offset = OffsetSpec.new(value: value)
        def cursor(value) = @cursor = CursorSpec.new(value: value)
        def consistency(mode, timeout: nil) = @consistency = ConsistencySpec.new(mode: mode, timeout: timeout)
        def freshness(mode, max_age: nil) = @freshness = FreshnessSpec.new(mode: mode, max_age: max_age)
        def authorize(policy, tenant: nil) = @authorization = AuthorizationSpec.new(policy: policy, tenant: tenant)
        def nulls(mode) = @null_semantics = NullSemantics.new(mode: mode)
        def inspect_query(mode = :sql) = @inspection = InspectionSpec.new(mode: mode)

        def use_index(name)
          @index_hints ||= []
          @index_hints << IndexHint.new(name: name)
        end

        private

        def split_comparator(value)
          return [:eq, value] unless value.is_a?(Hash)

          op, operand = value.first
          unless value.size == 1 && COMPARATORS.include?(op.to_sym)
            raise ArgumentError,
                  "unknown comparator #{value.inspect} — expected one of #{COMPARATORS.join(', ')}"
          end
          [op.to_sym, operand]
        end
      end
    end
  end
end
