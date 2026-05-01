# = Hecks::Chapters::Packaging
#
# Chapter for selective chapter loading. Registers all available
# chapters and provides a DSL for loading only the ones you need.
#
#   Hecks.chapters :bluebook, :runtime
#   Hecks.chapters :all
#
#   domain = Hecks::Chapters::Packaging.definition
#   domain.aggregates.map(&:name)
#
module Hecks
  module Chapters
    # Hecks::Chapters::Packaging
    #
    # Selective chapter loading — register, select, and load framework chapters.
    #
    module Packaging
      def self.summary = "Selective chapter loading and framework packaging"

      def self.definition
        @definition ||= Chapters.definition_from_bluebook("packaging")
      end
    end
  end
end
