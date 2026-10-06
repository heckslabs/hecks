require_relative "behaviour/read_model"
require_relative "keyword_fields"

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

      # Every optional keyword of its own and what it holds when the declaration omits it;
      # any other keyword goes to the specification base.
      FIELD_DEFAULTS = {
        description: nil, reference_name: nil, reference_target: nil, aggregate_heads: [], group_by: [],
        count: nil, median_field: nil, sum_field: nil, avg_field: nil, min_field: nil,
        max_field: nil, percentile_field: nil, percentile_at: nil, any_field: nil, all_field: nil
      }.freeze

      # The reduction keywords, among `FIELD_DEFAULTS`, that `assign_reductions` reads.
      REDUCTION_KEYS = [:count, :median_field, :sum_field, :avg_field, :min_field, :max_field,
                        :percentile_field, :percentile_at, :any_field, :all_field].freeze

      # Nil `reference_name`/`reference_target` mean a rootless read model, so `&.` keeps
      # them nil. `count` through `all_field` are `Behaviour::ReadModel::REDUCTION_FIELDS`,
      # one keyword per wire field: `Assembly::Build`/`Reconstruction` construct this
      # generically off the contract's own flat field list (contracts.rb), so grouping
      # them into a nested object would break that reflection.
      #
      # @param name [String, Symbol] the read model's declared name
      # @param reference_name [Symbol, String, nil] the local reference attribute it roots at
      # @param reference_target [String, Symbol, nil] the rooted aggregate's name
      # @param aggregate_heads [Array<Hash{Symbol => Object}>] rows of `:aggregate`, `:as`, `:many`
      # @param group_by [Array<Hash{field: Symbol}>] the declared group-by fields, one row each
      def initialize(name:, **given)
        fields = KeywordFields.fill(given.slice(*FIELD_DEFAULTS.keys), FIELD_DEFAULTS)
        super(joins: fields[:aggregate_heads], **given.except(*FIELD_DEFAULTS.keys))
        @name             = name.to_s
        @hecks_name       = @name
        # `group_by` rows are `{field: :agg}` hashes, the same shape as `aggregate_heads`.
        KeywordFields.assign(self, fields.slice(:description, :aggregate_heads, :group_by))
        @reference_name   = fields[:reference_name]&.to_sym
        @reference_target = fields[:reference_target]&.to_s
        assign_reductions(**fields.slice(*REDUCTION_KEYS))
      end

      # Every reduction is omitted from the export, not nil, when undeclared, so
      # existing read models keep their wire shape.
      #
      # @return [Hash] the declared emission, with `aggregate_heads`/`group_by` rows
      #   stringified, each reduction merged in only when declared, and
      #   `extra_options_to_h`'s own dynamic tail merged last
      def to_h
        super
          .merge(aggregate_heads: @aggregate_heads.map { |head| head.merge(as: head[:as].to_s) })
          .merge(group_by: @group_by.map { |row| row.merge(field: row[:field].to_s) })
          .merge(reduction_pairs)
          .merge(extra_options_to_h)
      end

      private

      # Stays nil (never false) when undeclared: the Judge skips setters whose source is nil.
      def assign_reductions(count:, percentile_at:, **fields)
        @count         = count ? true : nil
        @percentile_at = percentile_at&.to_f
        fields.each { |key, value| instance_variable_set(:"@#{key}", value&.to_sym) }
      end

      def reduction_pairs
        REDUCTION_KEYS.each_with_object({}) do |key, pairs|
          pairs[key] = emitted_reduction(key) if declared_reduction?(key)
        end
      end

      # `percentile_at` is emitted whenever its field is, even if the point itself is nil.
      def declared_reduction?(key)
        gate = key == :percentile_at ? :percentile_field : key
        instance_variable_get(:"@#{gate}") ? true : false
      end

      def emitted_reduction(key)
        value = instance_variable_get(:"@#{key}")
        return value if key == :percentile_at

        key == :count ? true : value.to_s
      end
    end
  end
end
