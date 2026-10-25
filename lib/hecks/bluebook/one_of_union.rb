module Hecks
  module Bluebook
    # The reading of a tagged reference (`reference_to one_of(A, B), as: :subject`, ADR 0122):
    # its attribute carries the `one_of` relationship, its type is the tagged value object, and
    # that value object's `type` admits the closed set of the variants' names.
    module OneOfUnion
      # The relationship the attribute of a tagged reference carries.
      RELATIONSHIP = "one_of".freeze

      module_function

      # @param attribute [Bluebook::Attribute] any attribute
      # @return [Boolean] whether it is a tagged reference to a closed union
      def union?(attribute) = attribute.relationship == RELATIONSHIP

      # The tagged references `owner` declares.
      #
      # @param owner [Bluebook::Aggregate] the aggregate to read
      # @return [Array<Bluebook::Attribute>] each attribute carrying the `one_of` relationship
      def attributes(owner) = Array(owner.attributes).select { |attribute| union?(attribute) }

      # The aggregates a tagged reference may point at, in declared order.
      #
      # @param owner [Bluebook::Aggregate] the aggregate declaring `attribute`
      # @param attribute [Bluebook::Attribute] a tagged reference of `owner`
      # @return [Array<String>] the variants' aggregate names; empty when the shapes are missing
      def variants(owner, attribute)
        tagged = owner.value_object(attribute.type.to_s)
        admits = tagged&.attribute(:type)&.admits
        set = admits && owner.value_object(admits.split("::").last)
        set ? set.members.map { |member| member.to_h[:value].to_s } : []
      end
    end
  end
end
