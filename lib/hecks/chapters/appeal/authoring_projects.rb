# Hecks::Chapters::Appeal::AuthoringProjectsParagraph
#
# Domain paragraph for the authoring chapter of HecksAppeal.
# Defines aggregates for project management, domain exploration,
# and document editing.
#
#   Hecks::Chapters::Appeal::AuthoringProjectsParagraph.define(builder)
#
module Hecks
  module Chapters
    module Appeal
      module AuthoringProjectsParagraph
        def self.define(b)
          b.aggregate "Project" do
            description "A domain project workspace. Loads, creates, and manages domain directories."
            attribute :name, String
            attribute :path, String
            attribute :status, String, default: "closed"

            command "OpenProject" do
              description "Load an existing domain from a directory"
              attribute :path, String
              emits "ProjectOpened"
            end

            command "CreateProject" do
              description "Initialize a new domain with a name"
              attribute :name, String
              attribute :path, String
              emits "ProjectCreated"
            end

            command "CloseProject" do
              description "Close the current project and release resources"
              reference_to "Project"
              emits "ProjectClosed"
            end

            command "DiscoverProjects" do
              description "Scan a directory for hecks apps -- looks for bluebook.hec files"
              attribute :search_path, String
              emits "ProjectsDiscovered"
            end

            validation :name, presence: true
            validation :path, presence: true
          end

          b.aggregate "Explorer" do
            description "Browse and inspect parsed domain structure -- aggregates, commands, references."
            attribute :domain_name, String
            attribute :aggregate_names, list_of("ExplorerEntry")
            attribute :last_opened_path, String
            attribute :last_opened_domain, String

            value_object "ExplorerEntry" do
              description "A named item in the domain structure"
              attribute :name, String
              attribute :kind, String
            end

            reference_to "Project"

            command "LoadDomain" do
              description "Parse the project domain and populate the explorer tree"
              reference_to "Project"
              emits "DomainLoaded"
            end

            command "InspectAggregate" do
              description "Show details of an aggregate"
              attribute :aggregate_name, String
              emits "AggregateInspected"
            end

            command "InspectCommand" do
              description "Show details of a command"
              attribute :aggregate_name, String
              attribute :command_name, String
              emits "CommandInspected"
            end

            command "OpenFile" do
              description "Open a file from the project tree and record it as the last opened"
              reference_to "Project"
              attribute :path, String
              attribute :domain, String
              emits "FileOpened"
            end

            command "GetLastOpened" do
              description "Return the last opened file path and domain"
              reference_to "Explorer"
              emits "LastOpenedReturned"
            end

            command "ExportBluebook" do
              description "Export the current domain as a .bluebook file"
              attribute :format, String
              emits "BluebookExported"
            end

            query "ByKind" do |kind|
              where(kind: kind)
            end
          end

          b.aggregate "Document" do
            description "A source file open for editing. Tracks content, parse state, and dirty status."
            attribute :filename, String
            attribute :content, String
            attribute :dirty, String, default: "false"
            attribute :diagnostics, list_of("Diagnostic")

            value_object "Diagnostic" do
              description "A validation finding at a source location"
              attribute :line, Integer
              attribute :column, Integer
              attribute :severity, String
              attribute :message, String
            end

            reference_to "Project"

            command "OpenDocument" do
              description "Load a .hec file into the editor"
              reference_to "Project"
              attribute :filename, String
              emits "DocumentOpened"
            end

            command "EditDocument" do
              description "Apply a text change to the document"
              reference_to "Document"
              attribute :content, String
              emits "DocumentEdited"
            end

            command "SaveDocument" do
              description "Persist the document back to disk"
              reference_to "Document"
              emits "DocumentSaved"
            end

            command "ValidateDocument" do
              description "Parse and validate the document, producing diagnostics"
              reference_to "Document"
              emits "DocumentValidated"
            end

            validation :filename, presence: true
          end
        end
      end
    end
  end
end
