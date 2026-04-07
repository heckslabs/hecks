# Hecks::Chapters::Workshop::InternalsParagraph
#
# Paragraph covering workshop internals: Mermaid diagram builder,
# event/service serializers, policy flow builder, tour steps,
# message-not-understood error, and bluebook mode.
#
#   Hecks::Chapters::Workshop::InternalsParagraph.define(builder)
#
module Hecks
  module Chapters
    module Workshop
      module InternalsParagraph
        def self.define(b)
          b.aggregate "MermaidBuilder" do
            description "Builds Mermaid LR graph string from serialized aggregates with relationship edges"
            command "Build" do
              attribute :aggregates, String
            end
          end

          b.aggregate "EventSerializer" do
            description "Serializes playground event log into JSON-ready hashes with type, command, and payload"
            command "Serialize"
          end

          b.aggregate "ServiceSerializer" do
            description "Serializes domain services across loaded domains into JSON-ready hashes"
            command "Serialize"
          end

          b.aggregate "PolicyFlowBuilder" do
            description "Builds cross-aggregate policy flow edges from serialized aggregates"
            command "Build" do
              attribute :aggregates, String
            end
          end

          b.aggregate "SketchSteps" do
            description "Tour step definitions for the sketch phase: aggregates, attributes, lifecycle, transitions"
            command "CreateAggregateStep"
            command "AddAttributeStep"
            command "AddLifecycleStep"
            command "BrowseStep"
            command "ValidateStep"
          end

          b.aggregate "PlaySteps" do
            description "Tour step definitions for the play phase: entering play, executing commands, building"
            command "EnterPlayStep"
            command "CreateInstanceStep"
            command "QueryAllStep"
            command "CheckEventsStep"
            command "BuildStep"
          end

          b.aggregate "MessageNotUnderstood" do
            description "Smalltalk-inspired error for unknown aggregate handle methods with command suggestions"
            command "HandleMissing" do
              attribute :method_name, String
            end
          end

          b.aggregate "BluebookMode" do
            description "Workshop mixin for composing multiple domains as chapters with shared event bus"
            command "AddChapter" do
              attribute :name, String
            end
            command "ListChapters"
            command "ToBluebook"
          end
        end
      end
    end
  end
end
