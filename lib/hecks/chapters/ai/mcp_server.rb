# Hecks::Chapters::AI::McpServerParagraph
#
# Paragraph defining MCP server/connection aggregates:
# BluebookServer, McpConnection, and TypeResolver.
#
#   Hecks::Chapters.define_paragraphs(Hecks::Chapters::AI, builder)
#
module Hecks
  module Chapters
    module AI
      module McpServerParagraph
        def self.define(b)
          b.aggregate "BluebookServer" do
            description "Generates MCP server from a compiled domain with command/query/repo tools"
            command "Run"
          end

          b.aggregate "McpConnection" do
            description "MCP protocol connection adapter bridging listens_to declarations to BluebookServer"
            command "Run"
          end

          b.aggregate "TypeResolver" do
            description "Converts type strings to Ruby types or descriptor hashes"
            command "Resolve" do
              attribute :type_string, String
            end
          end
        end
      end
    end
  end
end
