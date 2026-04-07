# Hecks::Chapters::Workshop::SerializersParagraph
#
# Paragraph covering StateSerializer children: aggregate, event,
# service serializers, mermaid builder, and policy flow builder.
#
#   Hecks::Chapters::Workshop::SerializersParagraph.define(builder)
#
module Hecks
  module Chapters
    module Workshop
      module SerializersParagraph
        def self.define(b)
          b.aggregate "AggregateSerializer" do
            description "Serializes workshop aggregates into JSON-ready hashes with attributes, commands, and relationships"
            command "Serialize"
          end

          b.aggregate "EventSerializer" do
            description "Serializes playground event log into JSON-ready hashes with type, command, and payload"
            command "Serialize"
          end

          b.aggregate "MermaidBuilder" do
            description "Builds Mermaid LR graph string from serialized aggregates with relationship edges"
            command "Build" do
              attribute :aggregates, String
            end
          end

          b.aggregate "PolicyFlowBuilder" do
            description "Builds cross-aggregate policy flow edges from serialized aggregates"
            command "Build" do
              attribute :aggregates, String
            end
          end

          b.aggregate "ServiceSerializer" do
            description "Serializes domain services across loaded domains into JSON-ready hashes"
            command "Serialize"
          end
        end
      end
    end
  end
end
