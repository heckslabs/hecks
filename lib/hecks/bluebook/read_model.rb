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
                  :count, :median_field, :sum_field, :avg_field, :min_field, :max_field,
                  :percentile_field, :percentile_at, :any_field, :all_field

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
      # @param sum_field [Symbol, nil] the field it reduces to the total of
      # @param avg_field [Symbol, nil] the field it reduces to the mean of
      # @param min_field [Symbol, nil] the field it reduces to the smallest value of
      # @param max_field [Symbol, nil] the field it reduces to the largest value of
      # @param percentile_field [Symbol, nil] the field it reduces to one interpolated rank of
      # @param percentile_at [Float, nil] the rank `percentile_field` interpolates, `0.0..1.0`
      # @param any_field [Symbol, nil] the boolean field it reduces to "is any row true"
      # @param all_field [Symbol, nil] the boolean field it reduces to "are all rows true"
      def initialize(name:, description: nil, reference_name: nil, reference_target: nil, aggregate_heads: [],
                     group_by: [], count: nil, median_field: nil, sum_field: nil, avg_field: nil,
                     min_field: nil, max_field: nil, percentile_field: nil, percentile_at: nil,
                     any_field: nil, all_field: nil, **)
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
        @sum_field        = sum_field&.to_sym
        @avg_field        = avg_field&.to_sym
        @min_field        = min_field&.to_sym
        @max_field        = max_field&.to_sym
        @percentile_field = percentile_field&.to_sym
        @percentile_at    = percentile_at&.to_f
        @any_field        = any_field&.to_sym
        @all_field        = all_field&.to_sym
      end

      # Every reduction is omitted from the export, not nil, when undeclared, so
      # existing read models keep their wire shape.
      #
      # @return [Hash] the declared emission, with `aggregate_heads`/`group_by` rows
      #   stringified, each reduction merged in only when declared, and
      #   `extra_options_to_h`'s own dynamic tail merged last
      def to_h
        reductions = {}
        reductions[:count] = true if @count
        reductions[:median_field] = @median_field.to_s if @median_field
        reductions[:sum_field] = @sum_field.to_s if @sum_field
        reductions[:avg_field] = @avg_field.to_s if @avg_field
        reductions[:min_field] = @min_field.to_s if @min_field
        reductions[:max_field] = @max_field.to_s if @max_field
        reductions[:percentile_field] = @percentile_field.to_s if @percentile_field
        reductions[:percentile_at] = @percentile_at if @percentile_field
        reductions[:any_field] = @any_field.to_s if @any_field
        reductions[:all_field] = @all_field.to_s if @all_field
        super
          .merge(aggregate_heads: @aggregate_heads.map { |head| head.merge(as: head[:as].to_s) })
          .merge(group_by: @group_by.map { |row| row.merge(field: row[:field].to_s) })
          .merge(reductions)
          .merge(extra_options_to_h)
      end
    end
  end
end
