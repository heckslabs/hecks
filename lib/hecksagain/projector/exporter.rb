# Exporter — the IR as JSON.
#
# A SCAFFOLD, not the architecture. Every runtime is meant to read the NATIVE
# format — a .bluebook file is already Ruby, and both parsers should parse it.
# Handing Rust a JSON IR was a stepping stone that made semantic parity
# provable early, and it retires once the Rust parser exists.
#
# The mistake hecksagain exists to avoid is NOT "two parsers". It is two
# parsers whose agreement nobody CHECKS. Both parsers here are authored by hand
# — Rust is not generated from Ruby and never was — so the whole burden falls on
# bin/parity, which compares what the two runtimes DO rather than where they
# came from.
#
# The export stays useful regardless — as a debugging surface, and as the input
# to targets that genuinely want data rather than source (SQL, docs, a
# specializer). It is simply not the boundary it was once described as.
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
