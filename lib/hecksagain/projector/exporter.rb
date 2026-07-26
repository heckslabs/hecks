# Exporter — the IR as JSON.
#
# This is the ENTIRE boundary between runtimes. Ruby is the only parser ; every
# other target reads what Ruby produced and never sees a .bluebook file,
# because parsing the bluebook twice — once per language — is the exact mistake
# hecksagain exists to avoid.
#
# It lives in the projector rather than in a bin script because it is the first
# real projection, and the ones that follow (a Rust emitter rather than a Rust
# interpreter) belong beside it.
#
#   Projector::Exporter.json(runtime.registry)
require "json"

module Hecksagain
  module Projector
    module Exporter
      module_function

      # Every loaded domain, as plain data.
      def call(registry)
        registry.bluebooks.transform_values(&:to_h)
      end

      def json(registry)
        JSON.pretty_generate(call(registry))
      end
    end
  end
end
