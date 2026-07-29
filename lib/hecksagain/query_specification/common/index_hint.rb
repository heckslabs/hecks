module Hecksagain
  module QuerySpecification
    module Common
      IndexHint = Struct.new(:name, keyword_init: true) do
        def to_h = { name: name.to_s }
      end
    end
  end
end
