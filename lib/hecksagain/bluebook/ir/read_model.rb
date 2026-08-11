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

        attr_reader :name, :description, :reference_name, :reference_target, :aggregate_heads, :group_by

        # `reference_name:`/`reference_target:` are nil for a ROOTLESS read
        # model (no `reference_to` declared) — `&.` throughout, rather than
        # the `.to_s`/`.to_sym` this used to require unconditionally, so
        # `reference_target.nil?` stays a real, checkable fact for the
        # interpreter instead of silently becoming `""`.
        def initialize(name:, description: nil, reference_name: nil, reference_target: nil, aggregate_heads: [],
                       group_by: [], **options)
          super(joins: aggregate_heads, **options)
          @name             = name.to_s
          @hecks_name       = @name
          @description      = description
          @reference_name   = reference_name&.to_sym
          @reference_target = reference_target&.to_s
          @aggregate_heads  = aggregate_heads
          # Hash rows (`{field: :agg}`), same shape as `aggregate_heads` —
          # `group_by_fields` is the convenience reader everything but
          # `to_h`/the Judge's own generic walk actually wants.
          @group_by         = group_by
        end

        # `.to_sym` regardless of source — the DIRECT builder path stores
        # symbols, but `Reconstruction::Shapes#group_by_field` (the
        # replayed-from-the-meta-domain path every REAL boot actually
        # goes through) reads the field back as a String, the same way
        # `aggregate_heads`' own `:as` does. Row hash KEYS built by
        # `Value.materialize_unwrapped` are symbols (`attr.name`), so
        # this has to be too, or `row[field]` in `nest` silently misses.
        def group_by_fields = @group_by.map { |row| row[:field].to_sym }

        def query_name = Naming.snake(@name)

        # The one many-side head where/order_by/limit/offset/authorize's
        # tenant apply to, or nil if none are declared —
        # ReadModelBuilder#seal_query_options already refuses ambiguity
        # (zero or several many-heads with options declared), so any
        # interpreter can ask this directly rather than re-deriving or
        # re-checking it.
        def filtered_head_name
          return nil unless wheres.any? || order_by || limit || offset || authorization&.tenant || @group_by.any?

          @aggregate_heads.find { |head| head[:many] }&.fetch(:as)
        end

        def to_h
          { name: @name, description: @description, reference_name: @reference_name,
            reference_target: @reference_target, query_name: query_name }
            .merge(aggregate_heads: @aggregate_heads.map { |head| head.merge(as: head[:as].to_s) })
            .merge(group_by: @group_by.map { |row| row.merge(field: row[:field].to_s) })
            .merge(extra_options_to_h)
        end
      end
    end
  end
end
