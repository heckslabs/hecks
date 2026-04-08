# Hecks::Chapters::Appeal::TestingConsoleParagraph
#
# Domain paragraph for the testing chapter of HecksAppeal.
# Defines aggregates for the interactive command console and
# live event stream viewer.
#
#   Hecks::Chapters::Appeal::TestingConsoleParagraph.define(builder)
#
module Hecks
  module Chapters
    module Appeal
      module TestingConsoleParagraph
        def self.define(b)
          b.aggregate "Console" do
            description "Interactive command runner GUI. Select aggregate and command, fill form, execute."
            attribute :selected_aggregate, String
            attribute :selected_command, String
            attribute :status, String, default: "idle"
            attribute :last_result, String
            attribute :event_log, list_of("ConsoleEvent")
            attribute :form, list_of("FormField")

            value_object "FormField" do
              description "A generated input field from a command attribute"
              attribute :name, String
              attribute :field_type, String
              attribute :required, String, default: "true"
              attribute :value, String
              attribute :error, String
            end

            value_object "ConsoleEvent" do
              description "An event recorded from command execution in the console"
              attribute :event_name, String
              attribute :payload, String
              attribute :timestamp, String
            end

            command "OpenConsole" do
              description "Open the console -- loads available aggregates and commands"
              reference_to "Console"
              emits "ConsoleOpened"
            end

            command "SelectCommand" do
              description "Pick an aggregate and command -- generates the input form"
              reference_to "Console"
              attribute :aggregate_name, String
              attribute :command_name, String
              emits "CommandSelected"
            end

            command "SubmitForm" do
              description "Execute the selected command with the filled form values"
              reference_to "Console"
              attribute :values, String
              emits "CommandExecuted"
            end

            command "ViewResult" do
              description "Display the result of the last command execution"
              reference_to "Console"
              emits "ResultViewed"
            end
          end

          b.aggregate "EventStream" do
            description "Live event feed. Subscribes to domain events and streams them to the UI."
            attribute :status, String, default: "streaming"
            attribute :events, list_of("StreamEvent")
            attribute :filter_aggregate, String
            attribute :filter_event_type, String

            value_object "StreamEvent" do
              description "A domain event captured from any running aggregate"
              attribute :event_name, String
              attribute :aggregate_name, String
              attribute :aggregate_id, String
              attribute :payload, String
              attribute :timestamp, String
              attribute :source_command, String
              attribute :source_policy, String
            end

            command "SubscribeToEvents" do
              description "Start streaming events from a project's domains"
              reference_to "EventStream"
              emits "EventsSubscribed"
            end

            command "StopStreaming" do
              description "Stop streaming events"
              reference_to "EventStream"
              emits "StreamingStopped"
            end

            command "PauseStream" do
              description "Temporarily pause the event stream without disconnecting"
              reference_to "EventStream"
              emits "StreamPaused"
            end

            command "ResumeStream" do
              description "Resume a paused event stream"
              reference_to "EventStream"
              emits "StreamResumed"
            end

            command "ClearEvents" do
              description "Remove all events from the stream display"
              reference_to "EventStream"
              emits "EventsCleared"
            end

            command "FilterEvents" do
              description "Filter the stream by aggregate name or event type"
              reference_to "EventStream"
              attribute :aggregate_name, String
              attribute :event_type, String
              emits "EventsFiltered"
            end

            command "InspectEvent" do
              description "Expand an event row to show its full payload data"
              reference_to "EventStream"
              attribute :event_name, String
              attribute :timestamp, String
              emits "EventInspected"
            end
          end
        end
      end
    end
  end
end
