# Hecks::Chapters::Appeal::AuthoringToolsParagraph
#
# Domain paragraph for the authoring chapter of HecksAppeal.
# Defines aggregates for edit timeline, code generation, schema
# import, and reusable domain patterns.
#
#   Hecks::Chapters::Appeal::AuthoringToolsParagraph.define(builder)
#
module Hecks
  module Chapters
    module Appeal
      module AuthoringToolsParagraph
        def self.define(b)
          b.aggregate "Timeline" do
            description "Edit history with undo/redo. Tracks document changes as a linear sequence."
            attribute :entries, list_of("TimelineEntry")
            attribute :cursor, Integer, default: 0

            value_object "TimelineEntry" do
              description "A recorded change with before/after content"
              attribute :action, String
              attribute :detail, String
              attribute :timestamp, String
            end

            reference_to "Document"

            command "RecordChange" do
              description "Append a change to the timeline"
              reference_to "Document"
              attribute :action, String
              attribute :detail, String
            end

            command "Undo" do
              description "Move the cursor back one step and revert the change"
              end

            command "Redo" do
              description "Move the cursor forward and reapply the change"
              end
          end

          b.aggregate "Generator" do
            description "Build domain code for a target language. Preview output, diff against existing."
            attribute :target, String
            attribute :status, String, default: "idle"
            attribute :output_path, String
            attribute :artifacts, list_of("Artifact")

            value_object "Artifact" do
              description "A generated file with its content and diff status"
              attribute :filename, String
              attribute :content, String
              attribute :changed, String, default: "true"
            end

            reference_to "Project"

            command "SelectTarget" do
              description "Choose a build target -- ruby, go, rails, sinatra"
              reference_to "Project"
              attribute :target, String
            end

            command "BuildTarget" do
              description "Generate all code for the selected target"
              end

            command "PreviewArtifact" do
              description "Show the content of a single generated file"
              attribute :filename, String
            end

            command "CompareArtifact" do
              description "Compare generated output against existing file on disk"
              attribute :filename, String
            end

            validation :target, presence: true
          end

          b.aggregate "Pattern" do
            description "Reusable domain pattern library -- CRUD, event-sourced, saga, process manager."
            attribute :name, String
            attribute :category, String
            attribute :template, String
            attribute :parameters, list_of("PatternParameter")

            value_object "PatternParameter" do
              description "A configurable parameter when applying a pattern"
              attribute :name, String
              attribute :param_type, String
              attribute :default_value, String
              attribute :required, String, default: "true"
            end

            command "CreatePattern" do
              description "Define a new reusable pattern from an existing aggregate shape"
              attribute :name, String
              attribute :category, String
              attribute :template, String
            end

            command "ApplyPattern" do
              description "Scaffold an aggregate by applying a pattern with parameters"
              reference_to "Project"
              attribute :pattern_name, String
              attribute :aggregate_name, String
              attribute :parameters, String
            end

            command "ListPatterns" do
              description "Show all available patterns, optionally filtered by category"
              attribute :category, String
            end

            validation :name, presence: true
          end
        end
      end
    end
  end
end
