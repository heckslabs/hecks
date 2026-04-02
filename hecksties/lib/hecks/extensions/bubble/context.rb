# HecksBubble::Context
#
# DSL host for declaring aggregate-level field mappings. A context groups
# one or more aggregate mappers and provides +translate+ and +reverse+
# entry points that delegate to the appropriate mapper.
#
#   ctx = HecksBubble::Context.new do
#     map_aggregate :Pizza do
#       from_legacy :create,
#         rename: { pizza_nm: :name },
#         transform: { name: ->(v) { v.strip.capitalize } }
#       map_out :create, rename: { name: :pizza_nm }
#     end
#   end
#
#   ctx.translate(:Pizza, :create, pizza_nm: " pepperoni ")
#   # => { name: "Pepperoni" }
#
module HecksBubble
  class Context
    # Build a context by evaluating the given block.
    #
    # @yield the DSL block containing +map_aggregate+ calls
    def initialize(&block)
      @mappers = {}
      instance_eval(&block) if block
    end

    # Declare mappings for an aggregate.
    #
    # @param name [Symbol] the aggregate name (e.g. :Pizza)
    # @yield evaluated in the scope of an {AggregateMapper}
    # @return [void]
    def map_aggregate(name, &block)
      mapper = AggregateMapper.new
      mapper.instance_eval(&block) if block
      @mappers[name] = mapper
    end

    # Translate legacy data into domain command attributes.
    #
    # @param aggregate [Symbol] the aggregate name
    # @param action [Symbol] the command action
    # @param data [Hash{Symbol => Object}] legacy data
    # @return [Hash{Symbol => Object}] translated domain attributes
    def translate(aggregate, action, data)
      mapper = @mappers[aggregate]
      return data unless mapper

      mapper.translate(action, data)
    end

    # Reverse-translate domain attributes to legacy field names.
    #
    # @param aggregate [Symbol] the aggregate name
    # @param action [Symbol] the command action
    # @param data [Hash{Symbol => Object}] domain data
    # @return [Hash{Symbol => Object}] legacy-keyed hash
    def reverse(aggregate, action, data)
      mapper = @mappers[aggregate]
      return data unless mapper

      mapper.reverse(action, data)
    end

    # Return the mapper for a given aggregate, or nil if none declared.
    #
    # @param name [Symbol] the aggregate name
    # @return [AggregateMapper, nil]
    def mapper_for(name)
      @mappers[name]
    end

    # List all aggregate names that have mappings.
    #
    # @return [Array<Symbol>]
    def mapped_aggregates
      @mappers.keys
    end
  end
end
