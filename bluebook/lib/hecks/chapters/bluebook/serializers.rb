# Hecks::Chapters::Bluebook::SerializersParagraph
#
# Paragraph covering serializer classes: the visitors that convert
# domain IR back into Bluebook DSL source code, handling aggregates,
# behaviors, rules, and type formatting.
#
#   Hecks::Chapters::Bluebook::SerializersParagraph.define(builder)
#
module Hecks
  module Chapters
    module Bluebook
      module SerializersParagraph
        def self.define(b)
          b.aggregate "AggregateSerializer", "Serializes aggregate IR back to Bluebook DSL source" do
            command("SerializeAggregate") { attribute :aggregate_id, String }
          end

          b.aggregate "BehaviorSerializer", "Serializes commands, events, and policies to DSL source" do
            command("SerializeBehavior") { attribute :aggregate_id, String }
          end

          b.aggregate "RuleSerializer", "Serializes validation rules to DSL source" do
            command("SerializeRules") { attribute :aggregate_id, String }
          end

          b.aggregate "TypeHelpers", "Type name formatting utilities for serializer output" do
            command("FormatType") { attribute :type_name, String }
          end
        end
      end
    end
  end
end
