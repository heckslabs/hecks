# = Hecks::Chapters::Packaging
#
# Chapter for selective chapter loading. Registers all available
# chapters and provides a DSL for loading only the ones you need.
#
#   Hecks.chapters :bluebook, :runtime
#   Hecks.chapters :all
#
# Or via a HecksChapters file in the project root:
#
#   chapter :bluebook
#   chapter :runtime
#
module Hecks
  module Chapters
    # Hecks::Chapters::Packaging
    #
    # Selective chapter loading — register, select, and load framework chapters.
    #
    module Packaging
      def self.summary = "Selective chapter loading and framework packaging"
    end
  end
end
