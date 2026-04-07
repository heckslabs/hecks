# Hecks::Chapters::AI::PromptsParagraph
#
# Paragraph listing the DomainGeneration sibling aggregate:
# DomainToolSchema. Used by load_aggregates to derive
# the require path from the aggregate name.
#
#   Hecks::Chapters.load_aggregates(
#     Hecks::Chapters::AI::PromptsParagraph,
#     base_dir: __dir__
#   )
#
module Hecks
  module Chapters
    module AI
      module PromptsParagraph
        def self.define(b)
          b.aggregate "DomainToolSchema" do
            description "Anthropic tool_use schema for the define_domain tool"
            command "GetSchema"
          end
        end
      end
    end
  end
end
