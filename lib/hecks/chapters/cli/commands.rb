# = Hecks::Chapters::Cli::CliCommands
#
# Self-describing sub-chapter for individual CLI commands. Each command
# is a Thor subcommand under `hecks <command>`.
#
#   Hecks::Chapters::Cli::CliCommands.define(builder)
#
module Hecks
  module Chapters
    module Cli
      # Hecks::Chapters::Cli::CliCommands
      #
      # Bluebook sub-chapter defining all individual CLI commands as aggregates.
      #
      module CliCommands
        def self.define(b)
          b.aggregate "InitCommand", "Scaffolds a new Hecks domain project" do
            command("Init") { attribute :project_name, String }
          end

          b.aggregate "BuildCommand", "Compiles domain DSL into Ruby classes" do
            command("Build") { attribute :target, String }
          end

          b.aggregate "ValidateCommand", "Lints a domain definition for errors" do
            command("Validate") { attribute :domain_path, String }
          end

          b.aggregate "ListCommand", "Lists aggregates and commands in a domain" do
            command("List") { attribute :domain_path, String }
          end

          b.aggregate "InspectCommand", "Displays detailed domain structure" do
            command("Inspect") { attribute :domain_path, String }
          end

          b.aggregate "TreeCommand", "Renders domain as ASCII tree" do
            command("Tree") { attribute :domain_path, String }
          end

          b.aggregate "DiffCommand", "Shows diff between domain versions" do
            command("Diff") { attribute :from_version, String; attribute :to_version, String }
          end

          b.aggregate "DumpCommand", "Exports domain in various formats" do
            command("Dump") { attribute :format, String }
          end

          b.aggregate "GemCommand", "Packages domain as a Ruby gem" do
            command("Package") { attribute :domain_path, String }
          end

          b.aggregate "ImportCommand", "Imports Rails models into domain DSL" do
            command("Import") { attribute :source_path, String }
          end

          b.aggregate "InterviewCommand", "Runs interactive domain wizard" do
            command("Interview") { attribute :domain_name, String }
          end

          b.aggregate "VersionCommand", "Shows framework version" do
            command("Show") { attribute :format, String }
          end

          b.aggregate "VersionTagCommand", "Tags a domain version snapshot" do
            command("Tag") { attribute :version, String }
          end

          b.aggregate "VersionLogCommand", "Lists domain version history" do
            command("Log") { attribute :domain_path, String }
          end

          b.aggregate "VisualizeCommand", "Generates domain diagrams" do
            command("Visualize") { attribute :format, String }
          end

          b.aggregate "ContextMapCommand", "Generates context map for multi-domain" do
            command("Generate") { attribute :domain_path, String }
          end

          b.aggregate "GlossaryCommand", "Outputs ubiquitous language glossary" do
            command("Generate") { attribute :domain_path, String }
          end

          b.aggregate "LlmsCommand", "Generates LLM context file" do
            command("Generate") { attribute :domain_path, String }
          end

          b.aggregate "ExtractCommand", "Extracts aggregate to new domain" do
            command("Extract") { attribute :aggregate_name, String }
          end

          b.aggregate "GenerateStubCommand", "Generates test stubs for domain" do
            command("Generate") { attribute :domain_path, String }
          end

          b.aggregate "GenerateSinatraCommand", "Generates Sinatra app from domain" do
            command("Generate") { attribute :domain_path, String }
          end

          b.aggregate "GenerateConfigCommand", "Generates configuration files" do
            command("Generate") { attribute :domain_path, String }
          end

          b.aggregate "InfoCommand", "Shows domain metadata and stats" do
            command("Show") { attribute :domain_path, String }
          end

          b.aggregate "CompileCommand", "Compiles Hecks into a self-contained binary" do
            command("Compile") { attribute :output, String }
          end

          b.aggregate "ClaudeCommand", "Starts file watchers and launches Claude Code" do
            command("Launch") { attribute :args, String }
          end

          b.aggregate "AppealCommand", "Launches the HecksAppeal IDE server" do
            command("Launch") { attribute :path, String }
          end

          b.aggregate "NewProjectCommand", "Scaffolds a new Hecks domain project" do
            command("Create") { attribute :project_name, String }
          end

          b.aggregate "SelfDiffCommand", "Compares generated code against actual gem code" do
            command("Diff") { attribute :chapter, String; attribute :framework, String }
          end

          b.aggregate "VerifyCommand", "Runs Bluebook self-verification" do
            command("Verify") { attribute :format, String }
          end

          b.aggregate "SmoketestCommand", "Runs all example domain tests" do
            command("Run") { attribute :format, String }
          end

          b.aggregate "AllureCommand", "Terminal UI — domain concepts as panels" do
            command("Launch") { attribute :bluebook, String }
          end

          b.aggregate "DocsCommand", "Serve domain as executable docs in browser" do
            command("Serve") { attribute :bluebook, String }
          end

          b.aggregate "ArchitectureCommand", "Show hexagonal architecture diagram" do
            command("Show") {}
          end

          b.aggregate "CoverageCommand", "Show missing domain concepts in app code" do
            command("Check") {}
          end

          b.aggregate "WinterCommand", "Wake Winter — living domain organism" do
            command("Wake") { attribute :action, String; attribute :domain, String }
          end

          b.aggregate "ConsoleCommand", "Start the interactive workshop" do
            command("Start") { attribute :name, String }
          end

          b.aggregate "WebWorkshopCommand", "Start the browser-based workshop" do
            command("Start") { attribute :name, String }
          end

          b.aggregate "TourCommand", "Guided walkthrough of the workshop" do
            command("Start") { attribute :architecture, String }
          end

          b.aggregate "StatsCommand", "Show comprehensive domain statistics" do
            command("Show") {}
          end

          b.aggregate "SmokeCommand", "Run end-to-end smoke test for this domain" do
            command("Run") {}
          end

          b.aggregate "RegenerateExamplesCommand", "Regenerate all example outputs from the pizzas domain" do
            command("Run") {}
          end

          b.aggregate "McpCommand", "Start MCP server — build domains or serve one" do
            command("Start") { attribute :domain, String }
          end

          b.aggregate "PromoteCommand", "Extract an aggregate into its own domain" do
            command("Promote") { attribute :aggregate, String }
          end
        end
      end
    end
  end
end
