require_relative "behaviour/read_model"

module Hecks
  module Bluebook
    # A read model: an ask that gathers heads from more than one aggregate.
    # Crosses over as an instance, like a query.
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

      # Nil `reference_name`/`reference_target` mean a rootless read model, so `&.` keeps them nil.
      #
      # @param name [String, Symbol] the read model's declared name
      # @param description [String, nil] the read model's declared prose description
      # @param reference_name [Symbol, String, nil] the local reference attribute it roots at
      # @param reference_target [String, Symbol, nil] the rooted aggregate's name
      # @param aggregate_heads [Array<Hash{Symbol => Object}>] rows of `:aggregate`, `:as`, `:many`
      # @param group_by [Array<Hash{field: Symbol}>] the declared group-by fields, one row each
      # @param count [Boolean, nil] whether it reduces to a row count
      # @param median_field [Symbol, nil] the field it reduces to the median of
      def initialize(name:, description: nil, reference_name: nil, reference_target: nil, aggregate_heads: [],
                     group_by: [], count: nil, median_field: nil, **)
        super(joins: aggregate_heads, **)
        @name             = name.to_s
        @hecks_name       = @name
        @description      = description
        @reference_name   = reference_name&.to_sym
        @reference_target = reference_target&.to_s
        @aggregate_heads  = aggregate_heads
        # Rows are `{field: :agg}` hashes, the same shape as `aggregate_heads`.
        @group_by         = group_by
        # Stays nil (never false) when undeclared: the Judge skips setters whose source is nil.
        @count            = count ? true : nil
        @median_field     = median_field&.to_sym
      end

      # `count`/`median_field` are omitted from the export, not nil, when undeclared, so
      # existing read models keep their wire shape.
      #
      # @return [Hash] the declared emission, with `aggregate_heads`/`group_by` rows
      #   stringified, `count`/`median_field` merged in only when declared, and
      #   `extra_options_to_h`'s own dynamic tail merged last
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
