module Hecksagain
  module QuerySpecification
    module Common
      NullSemantics = Struct.new(:mode, keyword_init: true) do
        def to_h = { mode: mode.to_s }

        def self.default = new(mode: :native)
      end
    end
  end
end
