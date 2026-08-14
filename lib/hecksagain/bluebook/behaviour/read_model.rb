module Hecksagain
  module Bluebook
    module Behaviour
      # WHAT A READ MODEL DOES. Its declared half is the gathered heads
      # and the query shape; these are readings taken off them.
      module ReadModel
        def group_by_fields = @group_by.map { |row| row[:field].to_sym }

        # `!!` rather than a bare `@count` — the DSL/reconstruction
        # boundary (ReadModel#initialize) already normalises to
        # `true`/`nil`, so this is belt and braces against a future
        # caller constructing a ReadModel by hand with `count: false`.
        def count? = !!@count

        def query_name = Naming.snake(@name)

        # WHICH GATHERED HEAD THE FILTERING APPLIES TO, so the read-model
        # interpreter can ask this directly rather than re-deriving or
        # re-checking it.
        def filtered_head_name
          return nil unless wheres.any? || order_by || limit || offset || authorization&.tenant ||
                            @group_by.any? || count? || @median_field

          @aggregate_heads.find { |head| head[:many] }&.fetch(:as)
        end
      end
    end
  end
end
