# Hecks::Chapters::AI
#
# Self-describing chapter definition for the hecks_ai gem.
# Enumerates every class and module under hecks_ai/lib/ as
# aggregates with their key commands. Aggregates are split
# into focused sub-domain files under ai/ by concern.
#
#   domain = Hecks::Chapters::AI.definition
#   domain.aggregates.map(&:name)
#   # => ["McpServer", "BluebookServer", "GovernanceGuard", ...]
#
require "bluebook"

require_relative "ai/mcp_tools"
require_relative "ai/mcp_server"
require_relative "ai/generation"
require_relative "ai/governance"

module Hecks
  module Chapters
    module AI
      def self.summary = "AI integration for Hecks"

      def self.definition
        Hecks::DSL::BluebookBuilder.new("AI").tap { |b|
          Chapters.define_paragraphs(AI, b)
        }.build
      end
    end
  end
end
