# Hecks::Chapters::HecksAppeal::ExplorationParagraph
#
# IDE exploration capabilities: browsing domain structure and inspecting elements.
#
#   Hecks::Chapters::HecksAppeal::ExplorationParagraph.define(builder)
#
module Hecks
  module Chapters
    module HecksAppeal
      module ExplorationParagraph
        def self.define(b)
          b.aggregate "Explorer" do
            description "Browse and inspect parsed domain structure — aggregates, commands, references."
            attribute :domain_name, String
            attribute :aggregate_names, list_of("ExplorerEntry")

            value_object "ExplorerEntry" do
              description "A named item in the domain structure"
              attribute :name, String
              attribute :kind, String
            end

            reference_to "Project"

            command "LoadDomain" do
              description "Parse the project domain and populate the explorer tree"
              reference_to "Project", validate: :exists
            end

            command "InspectAggregate" do
              description "Show details of an aggregate"
              attribute :aggregate_name, String
            end

            command "InspectCommand" do
              description "Show details of a command"
              attribute :aggregate_name, String
              attribute :command_name, String
            end

            query "ByKind" do |kind|
              where(kind: kind)
            end
          end
        end
      end
    end
  end
end
