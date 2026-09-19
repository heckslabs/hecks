module Hecks
  module Bluebook
    module Behaviour
      # What a query does beyond holding its declared shape.
      module Query
        # Finds a declared result attribute by name.
        #
        # @param named [String, Symbol] the attribute's declared name
        # @return [Bluebook::Attribute, nil] the attribute, or `nil` if none is declared
        #   by that name
        def attribute(named) = @attributes.find { |a| a.name == named.to_sym }
      end
    end
  end
end
