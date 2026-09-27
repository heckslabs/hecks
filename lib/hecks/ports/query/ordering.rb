require_relative "../../query_specification/common/null_policy"

module Hecks
  module Ports
    module Query
      # The order an ask answers in: the declared order_by, then identity as a total tiebreaker.
      #
      # An adapter that pushes ordering down must push limit down with it; re-ordering
      # a page the store already cut yields a top-N of the wrong N.
      module Ordering
        module_function

        # Orders rows by `order_by`, breaking ties by `identity`.
        #
        # @param rows [Array<Object>] the rows to order
        # @param order_by [QuerySpecification::Common::OrderBy, nil] nil orders by identity alone
        # @param null_semantics [QuerySpecification::Common::NullSemantics, nil] where nil values
        #   sort; nil uses the native default
        # @param identity [Proc] returns a row's comparable identity value
        # @yieldparam row [Object] one row being ordered
        # @yieldreturn [Object, nil] the row's comparable value for `order_by`'s field
        # @return [Array<Object>] the ordered rows
        def apply(rows, order_by, null_semantics = nil, identity:, &value_of)
          # The index keeps the sort stable; sort_by alone would order tied identities arbitrarily.
          rows = rows.each_with_index.sort_by { |row, index| [identity.call(row), index] }.map(&:first)
          return rows unless order_by

          QuerySpecification::Common::NullPolicy.order(
            rows, direction: order_by.direction, policy: null_semantics, &value_of
          )
        end
      end
    end
  end
end
