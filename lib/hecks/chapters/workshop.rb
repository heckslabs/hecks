# Hecks::Chapters::Workshop
#
# Self-describing chapter definition for the hecks_workshop gem.
# Enumerates every class and module under hecks_workshop/lib/ as
# aggregates with their key commands.
#
#   domain = Hecks::Chapters::Workshop.definition
#   domain.aggregates.map(&:name)
#   # => ["Workshop", "AggregateHandle", "CommandHandle", ...]
#
require "bluebook"

module Hecks
  module Chapters
    require_paragraphs(__FILE__)

    module Workshop
      def self.summary = "Interactive REPL and MCP server for Hecks"

      def self.definition
        Hecks::DSL::BluebookBuilder.new("Workshop").tap { |b|
          Chapters.define_paragraphs(Workshop, b)
        }.build
      end
    end
  end
end
