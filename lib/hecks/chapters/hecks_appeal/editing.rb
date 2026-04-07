# Hecks::Chapters::HecksAppeal::EditingParagraph
#
# IDE editing capabilities: document management, diagnostics, and undo/redo.
#
#   Hecks::Chapters::HecksAppeal::EditingParagraph.define(builder)
#
module Hecks
  module Chapters
    module HecksAppeal
      module EditingParagraph
        def self.define(b)
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
              reference_to "Project", validate: :exists
              attribute :filename, String
            end

            command "EditDocument" do
              description "Apply a text change to the document"
              reference_to "Document", validate: :exists
              attribute :content, String
            end

            command "SaveDocument" do
              description "Persist the document back to disk"
              reference_to "Document", validate: :exists
            end

            command "ValidateDocument" do
              description "Parse and validate the document, producing diagnostics"
              reference_to "Document", validate: :exists
            end

            validation :filename, presence: true
          end

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
              reference_to "Document", validate: :exists
              attribute :action, String
              attribute :detail, String
            end

            command "Undo" do
              description "Move the cursor back one step and revert the change"
              reference_to "Timeline", validate: :exists
            end

            command "Redo" do
              description "Move the cursor forward and reapply the change"
              reference_to "Timeline", validate: :exists
            end
          end
        end
      end
    end
  end
end
