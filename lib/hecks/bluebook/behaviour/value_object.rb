module Hecks
  module Bluebook
    module Behaviour
      # Behaviour of a value object; extended rather than included, since each shape is
      # its own class.
      module ValueObject
        # Recorded as its own fact so an empty `one_of` differs from no `one_of` at all.
        #
        # @return [Boolean] whether this value object declares `one_of`, even
        #   if left empty
        def closed_set? = @closed_set

        # Finds a declared attribute by its declared name.
        #
        # @param named [String, Symbol] the attribute's declared name
        # @return [Bluebook::Attribute, nil] the attribute named `named`, or
        #   `nil` if none is declared under that name
        def attribute(named) = attributes.find { |held| held.name == named.to_sym }

        # A single-attribute value object (EmailAddress{address}) names a scalar, not a group.
        #
        # A closed set's discriminant column is a different question and may span attributes.
        #
        # @return [Bluebook::Attribute, nil] this value object's only
        #   attribute, or `nil` when it has zero or more than one
        def sole_attribute
          attributes.first if attributes.size == 1
        end
      end
    end
  end
end
