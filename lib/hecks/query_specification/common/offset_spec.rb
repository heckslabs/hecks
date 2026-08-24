module Hecks
  module QuerySpecification
    module Common
      OffsetSpec = Struct.new(:value, keyword_init: true) do
        def to_h = { value: QuerySpecification.render_value(value) }
      end
    end
  end
end
