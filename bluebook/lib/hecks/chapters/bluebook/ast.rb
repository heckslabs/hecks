# Hecks::Chapters::Bluebook::AstParagraph
#
# Paragraph covering AST extraction and event storm import: Prism
# AST visitors for extracting domain definitions from Ruby source,
# and YAML event storm importers that convert event storming
# sessions into domain IR.
#
#   Hecks::Chapters::Bluebook::AstParagraph.define(builder)
#
module Hecks
  module Chapters
    module Bluebook
      module AstParagraph
        def self.define(b)
          b.aggregate "NodeReaders", "Shared AST node reading helpers for visitor classes" do
            command("ReadNode") { attribute :node_type, String }
          end

          b.aggregate "AggregateVisitor", "Prism AST visitor that extracts aggregate definitions from Ruby source" do
            command("VisitAggregate") { attribute :source, String }
          end

          b.aggregate "DomainVisitor", "Prism AST visitor that extracts domain-level definitions from Ruby source" do
            command("VisitDomain") { attribute :source, String }
          end

          b.aggregate "EventStormImporter", "Imports YAML event storming sessions into domain IR" do
            command("ImportEventStorm") { attribute :source, String; attribute :name, String }
          end

          b.aggregate "DslGenerator", "Generates Bluebook DSL from event storm parse results" do
            command("GenerateDsl") { attribute :result_id, String }
          end

          b.aggregate "YamlParser", "Parses YAML event storm files into structured data" do
            command("ParseYaml") { attribute :source, String }
          end

          b.aggregate "Result", "Container for event storm parse results" do
            command("CreateResult") { attribute :source, String }
          end

          b.aggregate "PatternMatching", "Pattern matching for event storm element classification" do
            command("MatchPattern") { attribute :text, String }
          end

          b.aggregate "ContextGrouping", "Groups event storm items by bounded context" do
            command("GroupByContext") { attribute :items, String }
          end

          b.aggregate "EventNameValidation", "Warns when event storm names don't match command inference convention" do
            command("ValidateEventNames") { attribute :source, String }
          end
        end
      end
    end
  end
end
