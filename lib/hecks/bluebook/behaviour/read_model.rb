module Hecks
  module Bluebook
    module Behaviour
      # **What a read model does**. Its declared half is the gathered heads
      # and the query shape; these are readings taken off them.
      module ReadModel
        # Lists the fields this read model groups rows by.
        #
        # @return [Array<Symbol>] each declared `group_by` field's name, in declaration order
        def group_by_fields = @group_by.map { |row| row[:field].to_sym }

        # `!!` rather than a bare `@count` — the DSL/reconstruction
        # boundary (ReadModel#initialize) already normalises to
        # `true`/`nil`, so this is belt and braces against a future
        # caller constructing a ReadModel by hand with `count: false`.
        #
        # @return [Boolean] whether this read model reduces to a row count
        def count? = !!@count

        # Names the verb `Dispatcher#query` looks this read model up by.
        #
        # @return [String] this read model's name in `snake_case`
        def query_name = Naming.snake(@name)

        # Which gathered heads the filtering applies to (ADR 0055) — plural,
        # since `where`/`order_by`/`limit`/`offset` can now each independently
        # name a many-side head via `on:` once there's more than one. A read
        # model with a single many-side head keeps the old reading: every
        # untargeted option (plus `group_by`/`count`/`median`, still
        # single-head-only — ADR 0055) applies to it, same as before `on:`
        # existed. With several many-side heads, only the ones actually named
        # by a targeted option are eligible.
        #
        # @return [Array<Symbol>] the `:as` name of each many-side head that filtering
        #   applies to; `[]` if this read model has no many-side head
        def filtered_head_names
          many = @aggregate_heads.select { |head| head[:many] }
          return [] if many.empty?

          return single_filtered_head_name(many) if many.one?

          targets = (wheres.map(&:target) + [order_by&.target, limit&.target, offset&.target]).compact.uniq
          targets.filter_map { |target| many.find { |head| head[:aggregate] == target.to_s } }.map { |head| head[:as] }
        end

        # The pre-`on:` reading (ADR 0055), unchanged: with exactly one
        # many-side head, every untargeted option (plus `group_by`/`count`/
        # `median`, still single-head-only) applies to it — split out only
        # to keep `filtered_head_names` itself under this file's own
        # complexity budget, not because the two questions differ in kind.
        #
        # @param many [Array<Hash{Symbol => Object}>] the read model's many-side
        #   `aggregate_heads` rows; must hold exactly one
        # @return [Array<Symbol>] `[the one head's :as name]` if any filtering option is
        #   declared, else `[]`
        def single_filtered_head_name(many)
          declared = wheres.any? || order_by || limit || offset || authorization&.tenant ||
                     @group_by.any? || count? || @median_field
          declared ? [many.first[:as]] : []
        end

        # The where/order_by/limit/offset that apply to one eligible head
        # (ADR 0055) — a small view `Ports::Query::InMemory.execute` reads
        # exactly the way it already reads a whole `Query`/`ReadModel`
        # (`.wheres`/`.order_by`/`.limit`/`.offset`/`.null_semantics`), scoped
        # to `head_as`'s own aggregate: an untargeted option applies when
        # `head_as` is the read model's one many-side head (the pre-`on:`
        # reading, unchanged) ; a targeted one applies when its `target`
        # resolves to `head_as`'s own aggregate.
        FilteredOptions = Struct.new(:wheres, :order_by, :limit, :offset, :null_semantics)

        # Scopes this read model's filtering options down to one included head.
        #
        # @param head_as [Symbol] the `:as` name of the head to scope filtering to
        # @return [FilteredOptions] the `wheres`/`order_by`/`limit`/`offset` that apply to
        #   `head_as`, and this read model's own `null_semantics`
        def options_for(head_as)
          many = @aggregate_heads.select { |head| head[:many] }
          aggregate_name = @aggregate_heads.find { |head| head[:as] == head_as }&.fetch(:aggregate)
          applies = lambda do |target|
            target.nil? ? many.one? : target.to_s == aggregate_name
          end

          FilteredOptions.new(
            wheres.select { |where| applies.call(where.target) },
            order_by && applies.call(order_by.target) ? order_by : nil,
            limit && applies.call(limit.target) ? limit : nil,
            offset && applies.call(offset.target) ? offset : nil,
            null_semantics
          )
        end
      end
    end
  end
end
