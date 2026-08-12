module Hecksagain
  class Bluebook
    module Behaviour
      # WHAT A QUERY DOES beyond holding its declared shape.
      module Query
        def attribute(named) = @attributes.find { |a| a.name == named.to_sym }
      end
    end
  end
end
