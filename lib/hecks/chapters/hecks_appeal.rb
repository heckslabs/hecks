# Hecks::Chapters::HecksAppeal
#
# Self-describing chapter for the HecksAppeal IDE domain.
# Defines capabilities any IDE frontend (web, CLI, native) can implement.
#
#   domain = Hecks::Chapters::HecksAppeal.definition
#   domain.aggregates.map(&:name)
#   # => ["Project", "Document", "Explorer", "Generator", "Playground", ...]
#
require "bluebook"

module Hecks
  module Chapters
    require_paragraphs(__FILE__)

    module HecksAppeal
      def self.summary = "IDE capabilities for Hecks"

      def self.definition
        Hecks::DSL::DomainBuilder.new("HecksAppeal").tap { |b|
          b.aggregate "Project" do
            description "A domain project workspace. Loads, creates, and manages domain directories."
            attribute :name, String
            attribute :path, String
            attribute :status, String, default: "closed"

            command "OpenProject" do
              description "Load an existing domain from a directory"
              attribute :path, String
            end

            command "CreateProject" do
              description "Initialize a new domain with a name"
              attribute :name, String
              attribute :path, String
            end

            command "CloseProject" do
              description "Close the current project and release resources"
              reference_to "Project", validate: :exists
            end

            validation :name, presence: true
            validation :path, presence: true
          end

          b.aggregate "Session" do
            description "IDE session with sketch/play modes. Sketch edits structure, play executes commands."
            attribute :mode, String, default: "sketch"

            command "EnterSketch" do
              description "Switch to sketch mode for editing domain structure"
              reference_to "Session", validate: :exists
            end

            command "EnterPlay" do
              description "Switch to play mode for executing domain commands"
              reference_to "Session", validate: :exists
            end
          end

          b.aggregate "Notification" do
            description "Feedback messages — errors, warnings, success confirmations, progress updates."
            attribute :severity, String
            attribute :message, String
            attribute :context, String
            attribute :dismissed, String, default: "false"

            command "Notify" do
              description "Create a notification for the user"
              attribute :severity, String
              attribute :message, String
              attribute :context, String
            end

            command "DismissNotification" do
              description "Mark a notification as seen"
              reference_to "Notification", validate: :exists
            end

            query "Active" do
              where(dismissed: "false")
            end
          end

          Chapters.define_paragraphs(HecksAppeal, b)
        }.build
      end
    end
  end
end
