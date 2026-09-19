require_relative "null_semantics"

module Hecks
  module QuerySpecification
    module Common
      # The attribute set every query-shaped construct shares — wheres,
      # ordering, paging, cursor, authorization, null semantics,
      # inspection mode — plus `options_to_h`/`extra_options_to_h` for
      # serializing it. Both Bluebook::Query and
      # QuerySpecification::ReadModel::Specification subclass this
      # rather than each declaring the same fields twice.
      class Options
        attr_reader :wheres, :order_by, :limit, :offset, :cursor,
                    :authorization, :null_semantics, :inspection

        # @param wheres [Array<WhereClause>] the filter clauses, all of which must hold
        # @param order_by [OrderBy, nil] the single ordering; `nil` leaves identity order
        # @param limit [LimitSpec, nil] the most rows returned; `nil` is unbounded
        # @param offset [OffsetSpec, nil] rows skipped before the limit; `nil` skips none
        # @param cursor [CursorSpec, nil] the cursor declaration; `nil` when none is declared
        # @param authorization [AuthorizationSpec, nil] the declared policy and tenant field;
        #   `nil` when the query declares no `authorize`
        # @param inspection [InspectionSpec, nil] the `inspect_query` request; `nil` when
        #   the query asks for none
        # @param null_semantics [NullSemantics, nil] where nulls sort; stored as given, so
        #   an explicit `nil` (what `ReadModelBuilder` passes when `nulls` was never
        #   written) stays `nil` rather than becoming the `native` default
        def initialize(wheres: [], order_by: nil, limit: nil, offset: nil, cursor: nil,
                       authorization: nil,
                       inspection: nil, null_semantics: NullSemantics.default)
          @wheres = wheres
          @order_by = order_by
          @limit = limit
          @offset = offset
          @cursor = cursor
          @authorization = authorization
          @null_semantics = null_semantics
          @inspection = inspection
        end

        # Serializes every shared option, declared or not, so a subclass's `to_h`
        # has one fixed set of keys to build on.
        #
        # @return [Hash{Symbol => Array<Hash>, Hash, nil}] keys `:wheres` (an Array of clause
        #   Hashes, `[]` when none), `:order_by`, `:limit`, `:offset`, `:cursor`,
        #   `:authorization`, `:null_semantics` and `:inspection`, each that spec's own
        #   `to_h` or `nil` when undeclared
        def options_to_h
          { wheres: @wheres.map(&:to_h), order_by: @order_by&.to_h, limit: @limit&.to_h,
            offset: @offset&.to_h, cursor: @cursor&.to_h, authorization: @authorization&.to_h,
            null_semantics: @null_semantics&.to_h, inspection: @inspection&.to_h }
        end

        # Serializes only the declared options beyond the settled three, so a
        # construct that never wrote one keeps its wire shape unchanged.
        #
        # @return [Hash{Symbol => Hash}] the subset of `options_to_h` that is set, without
        #   `:wheres`, `:order_by` and `:limit` (which the subclass emits itself) and
        #   without a `:null_semantics` of `{ mode: "native" }`; `{}` when nothing is
        def extra_options_to_h
          options_to_h.reject do |key, value|
            value.nil? || value == [] || (key == :null_semantics && value == { mode: "native" })
          end
                      .except(:wheres, :order_by, :limit)
        end
      end
    end
  end
end
