# Hecks::Chapters::Spec
#
# Self-describing chapter for Hecks' testing infrastructure.
# Covers spec generation, in-memory loading, memory adapters,
# test helpers, server test support, and the canonical Pizza/Order
# test domain used across the test suite.
#
#   domain = Hecks::Chapters::Spec.definition
#   domain.aggregates.map(&:name)
#   # => ["TestHelper", "InMemoryLoader", "MemoryAdapter", ...]
#
require "bluebook"

module Hecks
  module Chapters
    require_paragraphs(__FILE__)

    module Spec
      def self.definition
        @definition ||= Chapters.definition_from_bluebook("spec")
      end
    end
  end
end
