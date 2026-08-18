require_relative "authorization_spec"
require_relative "comparators"
require_relative "cursor_spec"
require_relative "inspection_spec"
require_relative "limit_spec"
require_relative "null_semantics"
require_relative "offset_spec"
require_relative "order_by"
require_relative "where_clause"

module Hecksagain
  module QuerySpecification
    module Common
      module DSL
        # RENAMED FROM `where`/`order_by`/`limit`/`offset`/`authorize`
        # (all below) — item #13's full metaprogrammed dispatch (slice
        # 4c). A SHARED mixin, same shape `attribute_impl` proved in
        # slice 3: ONE renamed method each, both Query and ReadModel
        # Keyword rows name it in `calls:`. `where`/`order_by` are
        # bootstrap-reachable (every core chapter's own `read_model`
        # filters its roster with them), so both are in
        # BOOTSTRAP_CALLS_FALLBACK for the ReadModel context; `limit`/
        # `offset`/`authorize` are not (checked directly).
        def where_impl(clauses)
          @wheres ||= []
          clauses.each do |field, value|
            op, operand = split_comparator(value)
            @wheres << WhereClause.new(field: field, op: op, value: operand)
          end
        end

        def order_by_impl(field, direction = :asc)
          @order_by = OrderBy.new(field: field, direction: direction)
        end

        def limit_impl(value) = @limit = LimitSpec.new(value: value)
        def offset_impl(value) = @offset = OffsetSpec.new(value: value)
        def cursor(value) = @cursor = CursorSpec.new(value: value)
        def authorize_impl(policy, tenant: nil) = @authorization = AuthorizationSpec.new(policy: policy, tenant: tenant)
        def nulls(mode) = @null_semantics = NullSemantics.new(mode: mode)
        def inspect_query(mode = :sql) = @inspection = InspectionSpec.new(mode: mode)

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
