# Hecks::Chapters::Appeal::CollaborationPlanningParagraph
#
# Domain paragraph for the collaboration chapter of HecksAppeal.
# Defines aggregates for story tracking and backlog management.
#
#   Hecks::Chapters::Appeal::CollaborationPlanningParagraph.define(builder)
#
module Hecks
  module Chapters
    module Appeal
      module CollaborationPlanningParagraph
        def self.define(b)
          b.aggregate "Story" do
            description "A unit of work -- feature, task, or bug."
            attribute :title, String
            attribute :description, String
            attribute :acceptance_criteria, String
            attribute :status, String, default: "todo"
            attribute :priority, Integer, default: 0

            command "CreateStory" do
              description "Define a new story with title and acceptance criteria"
              attribute :title, String
              attribute :description, String
              attribute :acceptance_criteria, String
            end

            command "StartStory" do
              description "Move a story to in-progress"
              reference_to "Story"
              end

            command "CompleteStory" do
              description "Mark a story as done"
              reference_to "Story"
              end

            command "AcceptStory" do
              description "Accept a completed story -- acceptance criteria met"
              reference_to "Story"
              end

            validation :title, presence: true

            query "InProgress" do
              where(status: "in_progress")
            end

            query "Todo" do
              where(status: "todo")
            end
          end

          b.aggregate "Backlog" do
            description "Ordered collection of stories. Tracks progress and readiness."
            attribute :name, String
            attribute :story_count, Integer, default: 0
            attribute :completed_count, Integer, default: 0
            attribute :ready, String, default: "false"

            command "AddToBacklog" do
              description "Add a story to the backlog"
              reference_to "Backlog"
              reference_to "Story"
            end

            command "Prioritize" do
              description "Reorder a story within the backlog"
              reference_to "Backlog"
              reference_to "Story"
              attribute :position, Integer
            end

            command "TrackProgress" do
              description "Recalculate completion and update readiness status"
              reference_to "Backlog"
              end

            validation :name, presence: true
          end
        end
      end
    end
  end
end
