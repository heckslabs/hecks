module Hecksagain
  module Ports
    module Query
      # What order an ask ANSWERS IN — the meaning of the ask, not a property
      # of the store that happens to hold it. Declared here once so an adapter
      # may satisfy it natively but never redefine it : SQLite pushes both
      # tiers into SQL (NullPolicy.sql_order renders `field DIR, id DIR`),
      # while Heki and Memory have no query engine and delegate straight back
      # to InMemory.
      #
      # Two tiers, in this order : the DECLARED order_by when there is one,
      # then IDENTITY, always. The identity tier is what makes an ask total.
      # Without it, an ask with no order_by — or a declared order with tied
      # keys — hands back whatever order the store happened to hold, which is
      # how a heki-backed Ruby and a heki-backed Rust came to disagree while
      # every hand-written query in the corpus stayed green : not one of them
      # had a tie for the two runtimes to disagree about.
      #
      # An adapter that pushes ordering down MUST push limit down with it.
      # Re-ordering a page the store already cut would be a top-N of the
      # wrong N — the one way this can be got quietly, expensively wrong.
      module Ordering
        module_function

        def apply(rows, order_by, null_semantics = nil, identity:, &value_of)
          # STABLE, because sort_by is not : two rows whose identity ties would
          # otherwise swap arbitrarily, and a tier meant to REMOVE store-dependence
          # would be adding a coin flip of its own.
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
