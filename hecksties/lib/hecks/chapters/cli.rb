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
      def self.definition
        DSL::DomainBuilder.new("Cli").tap { |b|
          b.aggregate "CLI", "Thor-based command-line interface entry point" do
            command("Start") { attribute :argv, String }
          end

          b.aggregate "Interviewer", "Interactive domain definition wizard" do
            command("Interview") { attribute :domain_name, String }
            command("BuildDomain") { attribute :answers, String }
          end

          b.aggregate "ArchitectureTour", "Guided walkthrough of a domain" do
            command("RunTour") { attribute :domain_name, String }
          end

          b.aggregate "WorldConcernsPrompt", "Prompts user for world concerns during init" do
            command("Prompt") { attribute :domain_name, String }
          end

          b.aggregate "ConflictHandler", "Handles file conflicts during generation" do
            command("Resolve") { attribute :file_path, String }
          end

          b.aggregate "DomainInspector", "Formats domain IR for terminal display" do
            command("InspectDomain") { attribute :domain_name, String }
          end

          Chapters.define_paragraphs(Cli, b)
        }.build
      end
    end
  end
end
