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
