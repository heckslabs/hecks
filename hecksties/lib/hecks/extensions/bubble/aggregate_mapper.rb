# HecksBubble::AggregateMapper
#
# Collects inbound and outbound field mappings for a single aggregate.
# Used inside a Context DSL block via +map_aggregate+ to declare how
# legacy fields translate to domain command attributes and back.
#
#   mapper = HecksBubble::AggregateMapper.new
#   mapper.from_legacy(:create,
#     rename: { pizza_nm: :name },
#     transform: { name: ->(v) { v.strip } })
#   mapper.map_out(:create, rename: { name: :pizza_nm })
#
#   mapper.translate(:create, pizza_nm: " Margherita ")
#   # => { name: "Margherita" }
#
#   mapper.reverse(:create, name: "Margherita")
#   # => { pizza_nm: "Margherita" }
#
module HecksBubble
  class AggregateMapper
    def initialize
      @inbound  = {}
      @outbound = {}
    end

    # Declare an inbound mapping for a command action.
    #
    # @param action [Symbol] the command action (e.g. :create, :update)
    # @param rename [Hash{Symbol => Symbol}] legacy key to domain key
    # @param transform [Hash{Symbol => Proc}] domain key to transform proc
    # @return [void]
    def from_legacy(action, rename: {}, transform: {})
      @inbound[action] = Mapping.new(rename: rename, transform: transform)
    end

    # Declare an outbound (reverse) mapping for a command action.
    #
    # @param action [Symbol] the command action
    # @param rename [Hash{Symbol => Symbol}] domain key to legacy key
    # @return [void]
    def map_out(action, rename: {})
      @outbound[action] = OutMapping.new(rename: rename)
    end

    # Translate legacy data into domain attributes using the inbound mapping.
    #
    # Applies field renames first, then value transforms on the renamed keys.
    # Unknown fields pass through unchanged.
    #
    # @param action [Symbol] the command action
    # @param data [Hash{Symbol => Object}] the legacy data hash
    # @return [Hash{Symbol => Object}] the translated domain attributes
    def translate(action, data)
      mapping = @inbound[action]
      return data unless mapping

      result = {}
      data.each do |key, value|
        new_key = mapping.rename.fetch(key, key)
        result[new_key] = value
      end

      mapping.transform.each do |key, fn|
        result[key] = fn.call(result[key]) if result.key?(key)
      end

      result
    end

    # Reverse-translate domain attributes back to legacy field names.
    #
    # Applies the outbound rename mapping. Unknown fields pass through.
    #
    # @param action [Symbol] the command action
    # @param data [Hash{Symbol => Object}] the domain attributes
    # @return [Hash{Symbol => Object}] the legacy-keyed hash
    def reverse(action, data)
      mapping = @outbound[action]
      return data unless mapping

      result = {}
      data.each do |key, value|
        new_key = mapping.rename.fetch(key, key)
        result[new_key] = value
      end
      result
    end
  end
end
