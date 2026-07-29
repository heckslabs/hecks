module Hecksagain
  module QuerySpecification
    module Common
      COMPARATORS = %i[eq ne gt gte lt lte in contains].freeze
    end
    def self.render_value(value) = value.is_a?(Symbol) ? ":#{value}" : value.to_s
  end
end
