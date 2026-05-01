# Hecks::Chapters::Bluebook::FeaturesParagraph
#
# Paragraph covering cross-cutting feature classes: leaky slice
# detection for cross-boundary dependency analysis and domain
# connection configuration.
#
#   Hecks::Chapters::Bluebook::FeaturesParagraph.define(builder)
#
module Hecks
  module Chapters
    module Bluebook
      module FeaturesParagraph
        def self.define(b)
          b.aggregate "LeakySliceDetection", "Detects cross-slice dependencies that violate bounded context boundaries" do
            command("DetectLeaks") { attribute :domain_id, String }
          end

          b.aggregate "ConnectionConfig", "Configures connections between domain contexts" do
            command("ConfigureConnection") { attribute :from_domain, String; attribute :to_domain, String }
          end

          b.aggregate "SliceStep", "Single step in a vertical slice through a reactive chain" do
            command("DefineStep") { attribute :command_name, String; attribute :event_name, String }
          end

          b.aggregate "DomainMixin", "Mixin adding vertical slice extraction to Domain IR" do
            command("ExtractSlices") { attribute :domain_id, String }
          end

          b.aggregate "VerticalSlice", "Cross-cutting slice through a command/event reactive chain" do
            command("Trace") { attribute :entry_command, String }
          end

          b.aggregate "SliceExtractor", "Extracts vertical slices from domain command flows" do
            command("Extract") { attribute :domain_id, String }
          end

          b.aggregate "SliceDiagram", "Generates Mermaid diagrams from vertical slices" do
            command("Generate") { attribute :domain_id, String }
          end
        end
      end
    end
  end
end
