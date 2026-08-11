module Hecksagain
  module Bluebook
    module IR
      # A read model — an ask that gathers heads from more than one aggregate.
      #
      # Like a query it crosses over as an INSTANCE, and for the same reason: its
      # body is inherited from `QuerySpecification::ReadModel::Specification`, whose
      # readers the runtime and the SQLite adapter both call on the object. It gains
      # an identity and an owner ; it keeps the name it always had, because only a
      # CLASS ever had a competing answer for `name`.
      class ReadModel < QuerySpecification::ReadModel::Specification
        include Construct

        attr_reader :name, :description, :reference_name, :reference_target, :aggregate_heads

        def initialize(name:, description: nil, reference_name:, reference_target:, aggregate_heads: [], **options)
          super(joins: aggregate_heads, **options)
          @name             = name.to_s
          @hecks_name       = @name
          @description      = description
          @reference_name   = reference_name.to_sym
          @reference_target = reference_target.to_s
          @aggregate_heads  = aggregate_heads
        end

        def query_name = Naming.snake(@name)

        # The one many-side head where/order_by/limit/offset/authorize's
        # tenant apply to, or nil if none are declared —
        # ReadModelBuilder#seal_query_options already refuses ambiguity
        # (zero or several many-heads with options declared), so any
        # interpreter can ask this directly rather than re-deriving or
        # re-checking it.
        def filtered_head_name
          return nil unless wheres.any? || order_by || limit || offset || authorization&.tenant

          @aggregate_heads.find { |head| head[:many] }&.fetch(:as)
        end

        # `wheres`/`order_by`/`limit` are spelled explicitly here, the SAME
        # mechanism `IR::Query#to_h` already uses (query.rb, read directly
        # before this was written) — always present, `wheres` a (possibly
        # empty) array and `order_by`/`limit` nil when undeclared, exactly
        # like a Query's. `extra_options_to_h` still excludes these three by
        # name (options.rb), so nothing here double-spells them; the two
        # constructs now share one encoding for the same three words rather
        # than a reader needing to learn a second one. See this file's own
        # `filtered_head_name` and language/bluebook/syntax.bluebook's
        # `ReadModel` `where`/`order_by`/`limit` member rows for the history
        # of why this WAS narrower, and 2026-08-11's read-model where/
        # order_by/limit task for why it stopped being.
        def to_h
          { name: @name, description: @description, reference_name: @reference_name,
            reference_target: @reference_target, query_name: query_name,
            wheres: wheres.map(&:to_h), order_by: order_by&.to_h, limit: limit&.to_h }
            .merge(aggregate_heads: @aggregate_heads.map { |head| head.merge(as: head[:as].to_s) })
            .merge(extra_options_to_h)
        end
      end
    end
  end
end
