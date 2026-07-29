module Hecksagain
  module Bluebook
    module IR
      class ReadModel < QuerySpecification::ReadModel::Specification
        attr_reader :name, :description, :reference_name, :reference_target, :aggregate_heads

        def initialize(name:, description: nil, reference_name:, reference_target:, aggregate_heads: [], **options)
          super(joins: aggregate_heads, **options)
          @name             = name.to_s
          @description      = description
          @reference_name   = reference_name.to_sym
          @reference_target = reference_target.to_s
          @aggregate_heads  = aggregate_heads
        end

        def query_name = Naming.snake(@name)

        def to_h
          { name: @name, description: @description, reference_name: @reference_name,
            reference_target: @reference_target, query_name: query_name }
            .merge(aggregate_heads: @aggregate_heads.map { |head| head.merge(as: head[:as].to_s) })
            .merge(extra_options_to_h)
        end
      end
    end
  end
end
