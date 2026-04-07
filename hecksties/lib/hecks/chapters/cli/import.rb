# = Hecks::Chapters::Cli::CliImport
#
# Self-describing sub-chapter for the Rails-to-Hecks import pipeline.
# Covers schema parsing, model parsing, domain assembly, and AST helpers.
#
#   Hecks::Chapters::Cli::CliImport.define(builder)
#
module Hecks
  module Chapters
    module Cli
      # Hecks::Chapters::Cli::CliImport
      #
      # Bluebook sub-chapter for the Rails-to-Hecks import pipeline aggregates.
      #
      module CliImport
        def self.define(b)
          b.aggregate "DomainAssembler", "Combines schema and model data into Hecks DSL source" do
            command("Assemble") { attribute :schema_data, String; attribute :model_data, String }
          end

          b.aggregate "ModelParser", "Parses Rails model files via Prism AST for associations and validations" do
            command("Parse") { attribute :models_dir, String }
          end

          b.aggregate "ModelOnlyAssembler", "Builds Hecks DSL from model files without schema.rb" do
            command("Assemble") { attribute :model_data, String }
          end

          b.aggregate "SchemaParser", "Evaluates Rails schema.rb in sandbox to capture table structure" do
            command("Parse") { attribute :schema_path, String }
          end

          b.aggregate "SchemaSandbox", "Sandboxed receiver for create_table calls during schema eval" do
            command("CreateTable") { attribute :name, String }
          end

          b.aggregate "ColumnCollector", "Captures column definitions from schema table blocks" do
            command("Collect") { attribute :type, String; attribute :name, String }
          end

          b.aggregate "PrismHelpers", "Prism AST node accessors shared by model parser extractors" do
            command("Extract") { attribute :call_node, String }
          end
        end
      end
    end
  end
end
