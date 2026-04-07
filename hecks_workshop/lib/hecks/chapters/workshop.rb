# Hecks::Chapters::Workshop
#
# Self-describing chapter definition for the hecks_workshop gem.
# Enumerates every class and module under hecks_workshop/lib/ as
# aggregates with their key commands.
#
#   domain = Hecks::Chapters::Workshop.definition
#   domain.aggregates.map(&:name)
#   # => ["Workshop", "AggregateHandle", "CommandHandle", ...]
#
require "bluebook"

module Hecks
  module Chapters
    require_paragraphs(__FILE__)

    module Workshop
      def self.definition
        Hecks::DSL::DomainBuilder.new("Workshop").tap { |b|
          b.aggregate "Workshop" do
            description "Interactive domain-building session for REPL-driven development"
            command "CreateSession" do
              attribute :name, String
            end
            command "AddAggregate" do
              attribute :name, String
            end
            command "RemoveAggregate" do
              attribute :aggregate_name, String
            end
            command "AddVerb" do
              attribute :word, String
            end
            command "Promote" do
              attribute :aggregate_name, String
            end
            command "ActivateActiveHecks"
          end

          b.aggregate "AggregateHandle" do
            description "Interactive handle for incrementally building a single aggregate in the REPL"
            command "AddAttribute" do
              attribute :name, String
              attribute :type, String
            end
            command "AddCommand" do
              attribute :name, String
            end
            command "AddPolicy" do
              attribute :name, String
            end
            command "AddLifecycle" do
              attribute :field, String
            end
            command "AddTransition" do
              attribute :from, String
              attribute :to, String
            end
          end

          b.aggregate "CommandHandle" do
            description "Interactive handle for adding attributes to a command after creation"
            command "AddAttribute" do
              attribute :name, String
              attribute :type, String
            end
          end

          b.aggregate "BuildActions" do
            description "Session methods for validating, previewing, building, and saving the domain"
            command "Validate"
            command "Preview"
            command "Build"
            command "Save"
            command "ToDsl"
          end

          b.aggregate "PlayMode" do
            description "Session mixin for play mode: executing commands against a live compiled domain"
            command "EnterPlay"
            command "ExitPlay"
            command "ResetPlayground"
          end

          b.aggregate "SystemBrowser" do
            description "Smalltalk-inspired tree view of all domain elements"
            command "Browse" do
              attribute :aggregate_name, String
            end
          end

          b.aggregate "DeepInspect" do
            description "Detailed aggregate structure display using Navigator and Renderer"
            command "Inspect" do
              attribute :aggregate_name, String
            end
          end

          b.aggregate "Navigator" do
            description "Traverses domain IR and yields each element with depth and path context"
            command "Walk" do
              attribute :aggregate_name, String
            end
            command "WalkAll"
          end

          b.aggregate "Renderer" do
            description "Formats domain IR elements into human-readable lines for deep_inspect"
            command "RenderAttribute"
            command "RenderCommand"
          end

          b.aggregate "SessionImage" do
            description "Point-in-time snapshot of a Workshop state for save/restore"
            command "Capture"
            command "Restore"
          end

          b.aggregate "PersistentImage" do
            description "File-based save/restore for SessionImage objects"
            command "SaveImage" do
              attribute :name, String
            end
            command "RestoreImage" do
              attribute :name, String
            end
            command "ListImages"
          end

          b.aggregate "Playground" do
            description "Live execution sandbox with memory adapters for rapid prototyping"
            command "Execute" do
              attribute :command_name, String
            end
            command "Reset"
          end

          b.aggregate "Tour" do
            description "Guided walkthrough of the sketch -> play -> build loop"
            command "Start"
          end

          b.aggregate "VisualizeMode" do
            description "Mermaid diagram visualization for the Workshop"
            command "Visualize" do
              attribute :format, String
            end
          end

          Chapters.define_paragraphs(Workshop, b)
        }.build
      end
    end
  end
end
