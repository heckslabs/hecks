module Hecks
  module QuerySpecification
    module Common
      OrderBy = Struct.new(:field, :direction, keyword_init: true) do
        def to_h = { field: field.to_s, direction: direction.to_s }
      end
    end
  end
end
