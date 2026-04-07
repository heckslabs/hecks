# Hecks::Chapters::HecksAppeal::GenerationParagraph
#
# IDE code generation capabilities: target selection, building, preview, and diff.
#
#   Hecks::Chapters::HecksAppeal::GenerationParagraph.define(builder)
#
module Hecks
  module Chapters
    module HecksAppeal
      module GenerationParagraph
        def self.define(b)
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
              description "Choose a build target — ruby, go, rails, sinatra"
              reference_to "Project", validate: :exists
              attribute :target, String
            end

            command "BuildTarget" do
              description "Generate all code for the selected target"
              reference_to "Generator", validate: :exists
            end

            command "PreviewArtifact" do
              description "Show the content of a single generated file"
              reference_to "Generator", validate: :exists
              attribute :filename, String
            end

            command "DiffArtifact" do
              description "Compare generated output against existing file on disk"
              reference_to "Generator", validate: :exists
              attribute :filename, String
            end

            validation :target, presence: true
          end
        end
      end
    end
  end
end
