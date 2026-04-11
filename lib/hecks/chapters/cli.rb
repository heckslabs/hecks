# = Hecks::Chapters::Cli
#
# Self-describing chapter for the Hecks CLI layer. Covers the Thor CLI,
# all CLI commands, domain tools (interviewer, architecture tour, smoke
# tests, import, stats), and code generation helpers.
#
#   domain = Hecks::Chapters::Cli.definition
#   domain.aggregates.map(&:name)
#
module Hecks
  module Chapters
    require_paragraphs(__FILE__)
    # Hecks::Chapters::Cli
    #
    # Bluebook chapter defining the CLI domain: all commands, tools, and workflow aggregates.
    #
    module Cli
      def self.summary = "Thor-based command-line interface for Hecks"

      def self.definition
        @definition ||= Chapters.definition_from_bluebook("cli")
      end
    end
  end
end
