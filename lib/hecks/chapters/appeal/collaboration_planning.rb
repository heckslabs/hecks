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
              emits "FeaturePlanned"
            end

            command "AddDomainAddition" do
              description "Manually add a planned domain change to the feature"
              attribute :kind, String
              attribute :name, String
              attribute :parent, String
              attribute :description, String
              emits "DomainAdditionAdded"
            end

            command "VerifyAdditions" do
              description "Check the live domain IR for each planned addition"
              emits "AdditionsVerified"
            end

            command "BuildFeature" do
              description "Ask the AI agent to implement all remaining additions"
              emits "FeatureBuildStarted"
            end

            command "CompleteFeature" do
              description "Mark the feature as done — all additions verified"
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
              attribute :feature_title, String
              emits "AddedToBacklog"
            end

            command "Prioritize" do
              description "Reorder a feature within the backlog"
              attribute :feature_title, String
              attribute :position, Integer
              emits "Reprioritized"
            end

            command "TrackProgress" do
              description "Recalculate completion across all features"
              emits "ProgressTracked"
            end

            validation :name, presence: true
          end

          b.aggregate "ProductExecutor" do
            description "Eight-agent product team: plan, build domain, build app, UX, UI, product owner, scrum master, event storming"
            attribute :active_agent, String
            attribute :conversations, list_of("AgentConversation")

            value_object "AgentConversation" do
              description "A named agent's chat history"
              attribute :agent_name, String
              attribute :messages, list_of(String)
            end

            command "SendToAgent" do
              description "Send a message to a named agent"
              attribute :agent_name, String
              attribute :content, String
              emits "AgentMessageSent"
            end

            command "SwitchAgent" do
              description "Switch the active agent tab"
              attribute :agent_name, String
              emits "AgentSwitched"
            end

            command "ClearAgent" do
              description "Clear an agent's conversation"
              attribute :agent_name, String
              emits "AgentCleared"
            end
          end

          b.aggregate "FeatureFlag" do
            description "Runtime toggle for shipped features. Enabled on ship, removed on acceptance."
            attribute :feature_title, String
            attribute :enabled, String, default: "true"
            attribute :permanent, String, default: "false"

            command "CreateFlag" do
              description "Create a feature flag when a feature ships"
              attribute :feature_title, String
              emits "FlagCreated"
            end

            command "ToggleFlag" do
              description "Enable or disable a feature flag at runtime"
              emits "FlagToggled"
            end

            command "RemoveFlag" do
              description "Remove the flag — feature becomes permanent"
              emits "FlagRemoved"
            end
          end
        end
      end
    end
  end
end
