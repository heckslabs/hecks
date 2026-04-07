# Hecks::Chapters::AI::InspectParagraph
#
# Paragraph listing the InspectTools sibling aggregate:
# DomainSerializer. Used by load_aggregates to derive
# the require path from the aggregate name.
#
#   Hecks::Chapters.load_aggregates(
#     Hecks::Chapters::AI::InspectParagraph,
#     base_dir: __dir__
#   )
#
module Hecks
  module Chapters
    module AI
      module InspectParagraph
        def self.define(b)
          b.aggregate "DomainSerializer" do
            description "Serializes a domain model into structured JSON for MCP tool responses"
            command "Serialize"
          end
        end
      end
    end
  end
end
