# Exporter — the IR as JSON.
#
# A SCAFFOLD, not the architecture. Every runtime is meant to read the NATIVE
# format — a .bluebook file is already Ruby, and both parsers should parse it.
# Handing Rust a JSON IR was a stepping stone that made semantic parity
# provable early, and it retires once the Rust parser exists.
#
# The mistake hecksagain exists to avoid is NOT "two parsers". It is two
# parsers authored twice BY HAND, kept in step by a suite that can only detect
# drift after the fact. A Rust parser that is a PROJECTION of the Ruby one is a
# different thing entirely: one author, two artifacts. Rust is a projection,
# except the interpreter.
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
