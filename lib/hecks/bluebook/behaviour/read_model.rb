module Hecks
  module Bluebook
    module Behaviour
      # What a read model does. Its declared half is the gathered heads
      # and the query shape; these are readings taken off them.
      module ReadModel
        # Lists the fields this read model groups rows by.
        #
        # @return [Array<Symbol>] each declared `group_by` field's name, in declaration order
        def group_by_fields = @group_by.map { |row| row[:field].to_sym }

        # Reports whether this read model's `group_by` names every identity
        # head of the aggregate it groups (ADR 0061).
        #
        # Such a key path can't be shared by two rows, so uniqueness is accepted
        # from the declaration alone rather than checked per request.
        #
        # @param aggregate [Bluebook::Aggregate, nil] the aggregate of this read
        #   model's one many-side head
        # @return [Boolean] false when `aggregate` is nil or declares no identity,
        #   since uniqueness cannot then be shown
        def groups_by_identity?(aggregate)
          return false unless aggregate

          identity = Array(aggregate.identity_heads).map(&:to_sym)
          !identity.empty? && (identity - group_by_fields).empty?
        end

        # `!!` guards against a future caller constructing a ReadModel by
        # hand with `count: false` rather than the normalised `nil`.
        #
        # @return [Boolean] whether this read model reduces to a row count
        def count? = !!@count

        # Names the verb `Dispatcher#query` looks this read model up by.
        #
        # @return [String] this read model's name in `snake_case`
        def query_name = Naming.snake(@name)

        # Which gathered heads the filtering applies to (ADR 0055): with one
        # many-side head every untargeted option applies to it; with several,
        # only the ones a targeted option names via `on:` are eligible.
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

        # Split out only to keep `filtered_head_names` under this file's own
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

        # Filtering options scoped to one included aggregate head (ADR 0055).
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
