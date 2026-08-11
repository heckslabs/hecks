require_relative "../../literal"

module Hecksagain
  module QuerySpecification
    module Common
      COMPARATORS = %i[eq ne gt gte lt lte in contains].freeze
    end

    # The specification structs' own name for the one wire spelling — see
    # Hecksagain::Literal, which every other `to_h`-bound literal field now
    # shares. Kept as a word here because the structs below read better
    # saying what they are doing than naming the module that does it.
    def self.render_value(value) = Literal.render(value)
  end
end
