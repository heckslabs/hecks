module Hecks
  module DomainModel
    module Structure

    # Hecks::DomainModel::Structure::ComputedAttribute
    #
    # A derived attribute computed from other attributes, not stored in the
    # database. Holds a name and a block whose body becomes a method on the
    # generated aggregate class.
    #
    #   ComputedAttribute.new(name: :lot_size, block: proc { area / 43560.0 })
    #
    class ComputedAttribute
      # @return [Symbol] the name of this computed attribute
      attr_reader :name

      # @return [Proc] the block whose body computes the derived value
      attr_reader :block

      # @param name [Symbol] attribute name
      # @param block [Proc] computation block referencing other attributes
      def initialize(name:, block:)
        @name = name
        @block = block
      end
    end
    end
  end
end
