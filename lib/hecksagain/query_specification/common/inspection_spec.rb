module Hecksagain
  module QuerySpecification
    module Common
      InspectionSpec = Struct.new(:mode, keyword_init: true) do
        def to_h = { mode: mode.to_s }
      end
    end
  end
end
