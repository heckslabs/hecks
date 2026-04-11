# Hecks::Chapters::Persist
#
# Self-describing chapter for the HecksPersist component. Covers SQL
# persistence via Sequel: database connection, adapter generation,
# schema generation, migration strategy, and boot wiring.
#
#   domain = Hecks::Chapters::Persist.definition
#   domain.aggregates.map(&:name)
#
require "bluebook"

module Hecks
  module Chapters
    module Persist
      def self.definition
        @definition ||= Chapters.definition_from_bluebook("persist")
      end
    end
  end
end
