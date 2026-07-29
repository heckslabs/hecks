module Hecksagain
  module QuerySpecification
    module Common
      ConsistencySpec = Struct.new(:mode, :timeout, keyword_init: true) do
        def to_h = { mode: mode.to_s, timeout: timeout && QuerySpecification.render_value(timeout) }
      end
    end
  end
end
