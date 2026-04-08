# Hecks::Chapters::Appeal::CollaborationPlanningParagraph
#
# Feature management with domain-driven verification.
# Stories decompose into domain additions (aggregates, commands, events).
# As additions appear in the domain IR, items turn green.
# AI agent plans domain additions and can build them.
#
module Hecks
  module Chapters
    module Appeal
      module CollaborationPlanningParagraph
        def self.define(b)
          b.aggregate "Feature" do
            description "A feature to build. Decomposes into domain additions tracked against the live IR."
            attribute :title, String
            attribute :description, String
            attribute :status, String, default: "draft"
            attribute :additions, list_of("DomainAddition")
            attribute :total_additions, Integer, default: 0
            attribute :completed_additions, Integer, default: 0

            value_object "DomainAddition" do
              description "A planned domain change — aggregate, command, event, attribute, or policy"
              attribute :kind, String
              attribute :name, String
              attribute :parent, String
              attribute :description, String
              attribute :exists_in_domain, String, default: "false"
            end

            command "CreateFeature" do
              description "Define a new feature with a title and description"
              attribute :title, String
              attribute :description, String
              emits "FeatureCreated"
            end

            command "PlanFeature" do
              description "Ask the AI agent to plan all domain additions for this feature"
              reference_to "Feature"
              emits "FeaturePlanned"
            end

            command "AddDomainAddition" do
              description "Manually add a planned domain change to the feature"
              reference_to "Feature"
              attribute :kind, String
              attribute :name, String
              attribute :parent, String
              attribute :description, String
              emits "DomainAdditionAdded"
            end

            command "VerifyAdditions" do
              description "Check the live domain IR for each planned addition"
              reference_to "Feature"
              emits "AdditionsVerified"
            end

            command "BuildFeature" do
              description "Ask the AI agent to implement all remaining additions"
              reference_to "Feature"
              emits "FeatureBuildStarted"
            end

            command "CompleteFeature" do
              description "Mark the feature as done — all additions verified"
              reference_to "Feature"
              emits "FeatureCompleted"
            end

            lifecycle :status, default: "draft" do
              transition "PlanFeature" => "planned", from: "draft"
              transition "BuildFeature" => "building", from: "planned"
              transition "VerifyAdditions" => "planned", from: "building"
              transition "CompleteFeature" => "done", from: "planned"
            end

            validation :title, presence: true
          end

          b.aggregate "Backlog" do
            description "Ordered collection of features. Tracks progress."
            attribute :name, String
            attribute :features, list_of("BacklogEntry")

            value_object "BacklogEntry" do
              description "A feature in the backlog with its position"
              attribute :feature_title, String
              attribute :position, Integer
              attribute :status, String
            end

            command "AddToBacklog" do
              description "Add a feature to the backlog"
              reference_to "Backlog"
              attribute :feature_title, String
              emits "AddedToBacklog"
            end

            command "Prioritize" do
              description "Reorder a feature within the backlog"
              reference_to "Backlog"
              attribute :feature_title, String
              attribute :position, Integer
              emits "Reprioritized"
            end

            command "TrackProgress" do
              description "Recalculate completion across all features"
              reference_to "Backlog"
              emits "ProgressTracked"
            end

            validation :name, presence: true
          end
        end
      end
    end
  end
end
