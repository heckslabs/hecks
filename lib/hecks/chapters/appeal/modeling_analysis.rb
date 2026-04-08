# Hecks::Chapters::Appeal::ModelingAnalysisParagraph
#
# Domain paragraph for the modeling chapter of HecksAppeal.
# Defines aggregates for domain health insights, migration
# detection, version comparison, and cross-domain policies.
#
#   Hecks::Chapters::Appeal::ModelingAnalysisParagraph.define(builder)
#
module Hecks
  module Chapters
    module Appeal
      module ModelingAnalysisParagraph
        def self.define(b)
          b.aggregate "Insight" do
            description "Domain health analysis -- coupling metrics, design smells, completeness checks."
            attribute :findings, list_of("Finding")
            attribute :score, Integer

            value_object "Finding" do
              description "A single analysis finding with severity and recommendation"
              attribute :rule, String
              attribute :severity, String
              attribute :element_name, String
              attribute :message, String
              attribute :recommendation, String
            end

            command "AnalyzeDomain" do
              description "Run all analysis rules against the current domain"
              attribute :scope, String
            end

            command "DismissInsight" do
              description "Acknowledge and hide a specific finding"
              reference_to "Insight"
              attribute :rule, String
              attribute :element_name, String
            end

            command "ConfigureRules" do
              description "Enable or disable specific analysis rules"
              reference_to "Insight"
              attribute :rule, String
              attribute :enabled, String
            end
          end

          b.aggregate "Migration" do
            description "Breaking change detection and migration path generation."
            attribute :from_version, String
            attribute :to_version, String
            attribute :status, String, default: "pending"
            attribute :changes, list_of("DomainChange")

            value_object "DomainChange" do
              description "A detected change -- added, removed, renamed, or modified element"
              attribute :kind, String
              attribute :element_type, String
              attribute :element_name, String
              attribute :detail, String
            end

            command "DetectChanges" do
              description "Compare current bluebook against a previous version"
              attribute :from_version, String
            end

            command "GenerateMigration" do
              description "Produce a migration script for the detected changes"
              reference_to "Migration"
              end

            command "ApplyMigration" do
              description "Execute the migration against a target environment"
              reference_to "Migration"
              end
          end

          b.aggregate "Comparison" do
            description "Side-by-side diff of two domain versions."
            attribute :left_version, String
            attribute :right_version, String
            attribute :differences, list_of("Difference")

            value_object "Difference" do
              description "A single difference between two domain versions"
              attribute :element_type, String
              attribute :element_name, String
              attribute :change_kind, String
              attribute :left_value, String
              attribute :right_value, String
              attribute :breaking, String, default: "false"
            end

            command "CompareVersions" do
              description "Diff two versions of the domain"
              attribute :left_version, String
              attribute :right_version, String
            end

            command "HighlightBreaking" do
              description "Filter the comparison to show only breaking changes"
              reference_to "Comparison"
              end
          end

          b.policy "ShowDiagramOnTabSelect" do
            on "TabSelected"
            trigger "GenerateDiagram"
            condition { |event| event[:active_tab] == "diagrams" }
          end
        end
      end
    end
  end
end
