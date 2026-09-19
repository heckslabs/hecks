require_relative "authorization_spec"
require_relative "comparators"
require_relative "cursor_spec"
require_relative "inspection_spec"
require_relative "limit_spec"
require_relative "null_semantics"
require_relative "offset_spec"
require_relative "order_by"
require_relative "where_clause"

module Hecks
  module QuerySpecification
    module Common
      # Shared builder-instance methods for the `where`/`order_by`/
      # `limit`/`offset`/`cursor`/`authorize`/`nulls`/`inspect_query`
      # bluebook DSL words, mixed into both QueryBuilder and
      # ReadModelBuilder so the two specification kinds parse the same
      # clauses identically rather than each carrying its own copy.
      module DSL
        # Records one `WhereClause` per `field => value` pair — what the
        # `where` DSL word forwards to.
        #
        # `where`/`order_by`/`limit`/`offset`/`authorize` (all below) carry
        # an `_impl` name because the words themselves are dispatched by
        # the grammar table rather than defined as methods: both the Query
        # and the ReadModel Keyword rows name the `_impl` method in
        # `calls:`, the same shape `attribute_impl` has, and a shared mixin
        # means one method each. `where`/`order_by` are bootstrap-reachable
        # (every core chapter's own `read_model` filters its roster with
        # them), so they must resolve through
        # `GenericDispatch::BOOTSTRAP_CALLS_FALLBACK` while the grammar
        # table is still being built.
        #
        # @param clauses [Hash{Symbol => Object}] field name (a dotted or slashed path is
        #   one Symbol) to either a literal, a Symbol naming a query argument, or a
        #   one-pair Hash `{ comparator => operand }` such as `{ gte: :minimum }`; a bare
        #   value means `eq`
        # @return [void]
        # @raise [ArgumentError] if a Hash value does not have exactly one pair, or names a
        #   comparator outside `COMPARATORS`
        def where_impl(clauses)
          @wheres ||= []
          clauses.each do |field, value|
            op, operand = split_comparator(value)
            @wheres << WhereClause.new(field: field, op: op, value: operand)
          end
        end

        # Records the query's single ordering, replacing any declared earlier.
        #
        # @param field [Symbol, String] the field to order by; a dotted path such as
        #   `:"order.value"` reaches a value object's member
        # @param direction [Symbol, String] `:asc` or `:desc`
        # @return [OrderBy] the ordering just recorded
        def order_by_impl(field, direction = :asc)
          @order_by = OrderBy.new(field: field, direction: direction)
        end

        # Records the most rows the query returns.
        #
        # @param value [Integer, Symbol] a literal row count, or a Symbol naming the query
        #   argument that supplies it
        # @return [LimitSpec] the limit just recorded
        def limit_impl(value) = @limit = LimitSpec.new(value: value)

        # Records how many matched rows the query skips before the limit applies.
        #
        # @param value [Integer, Symbol] a literal row count, or a Symbol naming the query
        #   argument that supplies it
        # @return [OffsetSpec] the offset just recorded
        def offset_impl(value) = @offset = OffsetSpec.new(value: value)

        # Records a cursor declaration. The word parses and round-trips, but both builders
        # refuse it at `build` (`seal_cursor`) because no interpreter applies it.
        #
        # @param value [Symbol, Object] the query argument carrying the cursor, such as
        #   `:after`, or a literal
        # @return [CursorSpec] the cursor just recorded
        def cursor(value) = @cursor = CursorSpec.new(value: value)

        # Records the authorization the query declares, and the argument that scopes it
        # to one tenant.
        #
        # @param policy [Symbol, String] name of the access policy, such as `:vault_access`
        # @param tenant [Symbol, String, nil] the field every ask must supply a value for
        #   and is filtered by (`Runtime::TenantScope`); `nil` declares no tenant scoping
        # @return [AuthorizationSpec] the authorization just recorded
        def authorize_impl(policy, tenant: nil) = @authorization = AuthorizationSpec.new(policy: policy, tenant: tenant)

        # Records where a null sorts, overriding the `native` default.
        #
        # @param mode [Symbol, String] `:first` or `:last`; anything else orders as
        #   `:native` does (see `NullPolicy.order`)
        # @return [NullSemantics] the null policy just recorded
        def nulls(mode) = @null_semantics = NullSemantics.new(mode: mode)

        # Records that the query asks its adapter to expose the query it generates.
        #
        # @param mode [Symbol, String] what to expose; `:sql` is the only mode
        #   `Ports::Query.validate!` lets an adapter without `inspect_query` serve
        # @return [InspectionSpec] the inspection request just recorded
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
