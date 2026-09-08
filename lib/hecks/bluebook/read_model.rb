require_relative "behaviour/read_model"

module Hecks
  module Bluebook
    # A read model — an ask that gathers heads from more than one aggregate.
    #
    # Like a query it crosses over as an INSTANCE, and for the same reason: its
    # body is inherited from `QuerySpecification::ReadModel::Specification`, whose
    # readers the runtime and the SQLite adapter both call on the object. It gains
    # an identity and an owner ; it keeps the name it always had, because only a
    # CLASS ever had a competing answer for `name`.
    class ReadModel < QuerySpecification::ReadModel::Specification
      include Construct

      include Hecks::IR
      include Behaviour::ReadModel

      emits_ir(
        name:             :name,
        description:      :description,
        reference_name:   :reference_name,
        reference_target: :reference_target,
        query_name:       :query_name,
        wheres:           many(:wheres),
        order_by:         one(:order_by),
        limit:            one(:limit)
      )

      attr_reader :name, :description, :reference_name, :reference_target, :aggregate_heads, :group_by,
                  :count, :median_field

      # `reference_name:`/`reference_target:` are nil for a ROOTLESS read
      # model (no `reference_to` declared) — `&.` throughout, rather than
      # the `.to_s`/`.to_sym` this used to require unconditionally, so
      # `reference_target.nil?` stays a real, checkable fact for the
      # interpreter instead of silently becoming `""`.
      def initialize(name:, description: nil, reference_name: nil, reference_target: nil, aggregate_heads: [],
                     group_by: [], count: nil, median_field: nil, **)
        super(joins: aggregate_heads, **)
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
        # ABSENT IS NOT FALSE. `@count` stays nil rather than becoming
        # `false` when undeclared — the same "if you declare it, declare
        # something" reading `Lifecycle`'s own optional fields rely on
        # (MetaValidator::Judge#setters skips a setter whose every
        # source is `nil`, so an ALWAYS-false `@count` would dispatch
        # `ReadModel.Count` on every read model that never wrote the
        # word at all). `!!count` collapses a truthy DSL `true` (or a
        # reconstructed `true`) to the same `true`/`nil` pair either path
        # produces — never `false`.
        @count            = count ? true : nil
        @median_field     = median_field&.to_sym
      end

      # `.to_sym` regardless of source — the DIRECT builder path stores
      # symbols, but `Reconstruction::Shapes#group_by_field` (the
      # replayed-from-the-meta-domain path every REAL boot actually
      # goes through) reads the field back as a String, the same way
      # `aggregate_heads`' own `:as` does. Row hash KEYS built by
      # `Value.materialize_unwrapped` are symbols (`attr.name`), so
      # this has to be too, or `row[field]` in `nest` silently misses.

      # `wheres`/`order_by`/`limit` are spelled explicitly here, the SAME
      # mechanism `Query#to_h` already uses (query.rb, read directly
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
      # Same dynamic tail as a Query's, plus two collections whose
      # ROWS are plain hashes rather than constructs — they are
      # normalised here rather than by `many`, which recurses through
      # `to_h` and would have nothing to call.
      # `count`/`median_field` are ABSENT (no key at all), not `nil`,
      # when undeclared — unlike `group_by` (always a `[]`, never
      # missing) they are the FIRST fields this construct has ever
      # added that no OLDER real corpus member could possibly carry, so
      # merging them unconditionally would have put a `null` onto every
      # existing read model's own wire shape (banking's
      # `ComplianceDashboard`/`CustomerPortfolio`, the language's own
      # `WholeBluebook`, ...) for a fact nothing about them changed —
      # the exact `extra_options_to_h` reads for `cursor`/`offset`/etc,
      # applied here for the same reason.
      def to_h
        reductions = {}
        reductions[:count] = true if @count
        reductions[:median_field] = @median_field.to_s if @median_field
        super
          .merge(aggregate_heads: @aggregate_heads.map { |head| head.merge(as: head[:as].to_s) })
          .merge(group_by: @group_by.map { |row| row.merge(field: row[:field].to_s) })
          .merge(reductions)
          .merge(extra_options_to_h)
      end
    end
  end
end
