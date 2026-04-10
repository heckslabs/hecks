# Hecks::Chapters::AI::GenerationParagraph
#
# Paragraph defining AI-driven domain generation aggregates:
# LlmClient, AiBluebookBuilder, DomainGeneration, DomainSerializer,
# and DomainToolSchema.
#
#   Hecks::Chapters.define_paragraphs(Hecks::Chapters::AI, builder)
#
module Hecks
  module Chapters
    module AI
      module GenerationParagraph
        def self.define(b)
          b.aggregate "LlmClient" do
            description "Minimal net/http client for Anthropic Messages API with tool_use"
            command "GenerateDomain" do
              attribute :description, String
            end
          end

          b.aggregate "AiBluebookBuilder" do
            description "Walks LLM JSON and replays through Workshop API to build a validated domain"
            command "Build"
          end

          b.aggregate "DomainGeneration" do
            description "System prompt with few-shot examples for LLM domain generation"
            command "GetPrompt"
          end

          b.aggregate "DomainSerializer" do
            description "Serializes a domain model into structured JSON for MCP tool responses"
            command "Serialize"
          end

          b.aggregate "DomainToolSchema" do
            description "Anthropic tool_use schema for the define_domain tool"
            command "GetSchema"
          end
        end
      end
    end
  end
end
