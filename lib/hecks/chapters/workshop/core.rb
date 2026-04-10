# Hecks::Chapters::Workshop::CoreParagraph
#
# Paragraph covering the core workshop aggregates: the root Workshop,
# interactive handles, build actions, and session image persistence.
#
#   Hecks::Chapters::Workshop::CoreParagraph.define(builder)
#
module Hecks
  module Chapters
    module Workshop
      module CoreParagraph
        def self.define(b)
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
        end
      end
    end
  end
end
