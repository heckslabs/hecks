# Hecks::Chapters::HecksAppeal::SandboxParagraph
#
# IDE sandbox capabilities: interactive command execution and state inspection.
#
#   Hecks::Chapters::HecksAppeal::SandboxParagraph.define(builder)
#
module Hecks
  module Chapters
    module HecksAppeal
      module SandboxParagraph
        def self.define(b)
          b.aggregate "Playground" do
            description "Interactive sandbox for running domain commands and inspecting state."
            attribute :events, list_of("PlaygroundEvent")
            attribute :state_snapshot, String

            value_object "PlaygroundEvent" do
              description "A recorded event from command execution"
              attribute :name, String
              attribute :payload, String
              attribute :timestamp, String
            end

            reference_to "Project"

            command "ExecuteCommand" do
              description "Run a domain command in the sandbox"
              reference_to "Project", validate: :exists
              attribute :aggregate_name, String
              attribute :command_name, String
              attribute :attributes, String
            end

            command "InspectState" do
              description "View current aggregate state in the sandbox"
              reference_to "Project", validate: :exists
              attribute :aggregate_name, String
            end

            command "ResetPlayground" do
              description "Clear all sandbox state and events"
              reference_to "Project", validate: :exists
            end

            query "RecentEvents" do
              where(timestamp: "recent")
            end
          end
        end
      end
    end
  end
end
