require "json"

module Hecksagain
  module Projector
    module Exporter
      module_function

      def call(registry)
        registry.bluebooks.transform_values(&:to_h)
      end

      def json(registry)
        JSON.pretty_generate(call(registry))
      end
    end
  end
end
