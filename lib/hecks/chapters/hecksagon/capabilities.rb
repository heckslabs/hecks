# Hecks::Chapters::Hecksagon::CapabilitiesParagraph
#
# Paragraph covering capability tagging and Hecksagon module-level
# autoload registry: AggregateCapabilityBuilder, AttributeSelector,
# TagApplier, and the Hecksagon namespace module.
#
#   Hecks::Chapters::Hecksagon::CapabilitiesParagraph.define(builder)
#
module Hecks
  module Chapters
    module Hecksagon
      module CapabilitiesParagraph
        def self.define(b)
          b.aggregate "AggregateCapabilityBuilder" do
            description "Fluent builder for per-aggregate capability tags via chained method calls"
            namespace "Hecksagon::DSL"
            command "AddCapability" do
              attribute :aggregate_name, String
            end
          end

          b.aggregate "AttributeSelector" do
            description "Fluent attribute selector that captures attribute name for capability tagging"
            namespace "Hecksagon::DSL"
            command "SelectAttribute" do
              attribute :attr_name, String
            end
          end

          b.aggregate "TagApplier" do
            description "Applies a capability tag to a selected attribute via method_missing"
            namespace "Hecksagon::DSL"
            command "ApplyTag" do
              attribute :tag_name, String
            end
          end

          b.aggregate "HecksagonModule" do
            description "Top-level Hecksagon namespace with autoload registry for DSL, Structure, and mixins"
            namespace "Hecksagon"
            command "Autoload" do
              attribute :const_name, String
              attribute :path, String
            end
          end
        end
      end
    end
  end
end
