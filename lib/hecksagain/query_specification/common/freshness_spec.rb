module Hecksagain
  module QuerySpecification
    module Common
      FreshnessSpec = Struct.new(:mode, :max_age, keyword_init: true) do
        def to_h = { mode: mode.to_s, max_age: max_age && QuerySpecification.render_value(max_age) }
      end
    end
  end
end
