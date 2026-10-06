require_relative "null_semantics"

module Hecks
  module QuerySpecification
    module Common
      # The attribute set every query-shaped construct shares, plus `options_to_h` and
      # `extra_options_to_h` for serializing it.
      class Options
        # The options besides `wheres`, in the order `options_to_h` writes them.
        SPEC_OPTIONS = %i[order_by limit offset cursor authorization null_semantics inspection].freeze

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
        def initialize(**options)
          refuse_unknown!(options)
          @wheres = options.fetch(:wheres, [])
          @order_by = options[:order_by]
          @limit = options[:limit]
          @offset = options[:offset]
          @cursor = options[:cursor]
          @authorization = options[:authorization]
          @null_semantics = options.fetch(:null_semantics) { NullSemantics.default }
          @inspection = options[:inspection]
        end

        # Serializes every shared option, declared or not, so a subclass's `to_h`
        # has one fixed set of keys to build on.
        #
        # @return [Hash{Symbol => Array<Hash>, Hash, nil}] keys `:wheres` (an Array of clause
        #   Hashes, `[]` when none), `:order_by`, `:limit`, `:offset`, `:cursor`,
        #   `:authorization`, `:null_semantics` and `:inspection`, each that spec's own
        #   `to_h` or `nil` when undeclared
        def options_to_h
          { wheres: @wheres.map(&:to_h) }.merge(SPEC_OPTIONS.to_h { |name| [name, public_send(name)&.to_h] })
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

        private

        def refuse_unknown!(options)
          unknown = options.keys - SPEC_OPTIONS - [:wheres]
          raise ArgumentError, "unknown keyword: #{unknown.first.inspect}" unless unknown.empty?
        end
      end
    end
  end
end
