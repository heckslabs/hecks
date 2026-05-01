# Hecks::Chapters::Appeal::TestingScenariosParagraph
#
# Domain paragraph for the testing chapter of HecksAppeal.
# Defines aggregates for executable scenarios, reusable fixtures,
# and the interactive playground sandbox.
#
#   Hecks::Chapters::Appeal::TestingScenariosParagraph.define(builder)
#
module Hecks
  module Chapters
    module Appeal
      module TestingScenariosParagraph
        def self.define(b)
          b.aggregate "Scenario" do
            description "Executable given/when/then specification. Tests domain commands without implementation."
            attribute :name, String
            attribute :status, String, default: "draft"
            attribute :steps, list_of(Step)
            attribute :result, String

            value_object "Step" do
              description "A single step in a scenario -- given, when, or then"
              attribute :phase, String
              attribute :aggregate_name, String
              attribute :command_name, String
              attribute :attributes, String
              attribute :expectation, String
            end

            command "CreateScenario" do
              description "Define a new scenario with a name"
              attribute :name, String
            end

            command "AddStep" do
              description "Append a given/when/then step to the scenario"
              attribute :phase, String
              attribute :aggregate_name, String
              attribute :command_name, String
              attribute :attributes, String
            end

            command "RunScenario" do
              description "Execute all steps and record pass/fail"
              end

            command "RecordResult" do
              description "Store the outcome of a scenario run"
              attribute :result, String
            end

            validation :name, presence: true
          end

          b.aggregate "Fixture" do
            description "Reusable data set for populating scenarios with known state."
            attribute :name, String
            attribute :entries, list_of(FixtureEntry)

            value_object "FixtureEntry" do
              description "A single data record -- aggregate name, attribute values"
              attribute :aggregate_name, String
              attribute :attributes, String
            end

            command "CreateFixture" do
              description "Define a new fixture set"
              attribute :name, String
            end

            command "AddEntry" do
              description "Add a data record to the fixture"
              attribute :aggregate_name, String
              attribute :attributes, String
            end

            command "ApplyToScenario" do
              description "Load this fixture as the given state for a scenario"
              reference_to Scenario
            end

            validation :name, presence: true
          end

          b.aggregate "Playground" do
            description "Interactive sandbox for running domain commands and inspecting state."
            attribute :events, list_of(PlaygroundEvent)
            attribute :state_snapshot, String

            value_object "PlaygroundEvent" do
              description "A recorded event from command execution"
              attribute :name, String
              attribute :payload, String
              attribute :timestamp, String
            end

            command "ExecuteCommand" do
              description "Run a domain command in the sandbox"
              attribute :aggregate_name, String
              attribute :command_name, String
              attribute :attributes, String
            end

            command "InspectState" do
              description "View current aggregate state in the sandbox"
              attribute :aggregate_name, String
            end

            command "ResetPlayground" do
              description "Clear all sandbox state and events"
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
