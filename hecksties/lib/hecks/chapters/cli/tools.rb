# = Hecks::Chapters::Cli::CliTools
#
# Self-describing sub-chapter for CLI support tools: smoke testing,
# stats, import pipeline, and stub generation.
#
#   Hecks::Chapters::Cli::CliTools.define(builder)
#
module Hecks
  module Chapters
    module Cli
      module CliTools
        def self.define(b)
          b.aggregate "SmokeTest", "Browser-style HTTP smoke tests for domains" do
            command("RunSmoke") { attribute :base_url, String }
            command("CheckEvents") { attribute :event_log, String }
            command("TestBehaviors") { attribute :domain_name, String }
          end

          b.aggregate "DomainStats", "Aggregate/command/event/policy counts" do
            command("Calculate") { attribute :domain, String }
          end

          b.aggregate "ProjectStats", "Project-wide metrics across all domains" do
            command("Calculate") { attribute :project_path, String }
          end

          b.aggregate "ImportPipeline", "Rails model import: parse, assemble, generate" do
            command("ParseModels") { attribute :source_path, String }
            command("ParseSchemas") { attribute :schema_path, String }
            command("AssembleDomain") { attribute :models, String }
          end

          b.aggregate "StubGenerator", "Generates test stub files for a domain" do
            command("Generate") { attribute :domain_name, String }
          end

          b.aggregate "DomainHelpers", "Shared helpers for CLI domain loading" do
            command("LoadDomain") { attribute :domain_path, String }
          end
        end
      end
    end
  end
end
