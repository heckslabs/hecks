# Hecks::Chapters::AI::DomainServerParagraph
#
# Paragraph listing the DomainServer child aggregates:
# CommandTools, QueryTools, and RepositoryTools. Used by
# load_aggregates to derive require paths from aggregate names.
#
#   Hecks::Chapters.load_aggregates(
#     Hecks::Chapters::AI::DomainServerParagraph,
#     base_dir: File.expand_path("domain_server", __dir__)
#   )
#
module Hecks
  module Chapters
    module AI
      module DomainServerParagraph
        def self.define(b)
          b.aggregate "CommandTools" do
            description "DomainServer mixin: registers MCP tools for domain commands"
            command "RegisterCommandTools"
          end

          b.aggregate "QueryTools" do
            description "DomainServer mixin: registers MCP tools for domain queries"
            command "RegisterQueryTools"
          end

          b.aggregate "RepositoryTools" do
            description "DomainServer mixin: registers Find/All/Count tools per aggregate"
            command "RegisterRepositoryTools"
          end
        end
      end
    end
  end
end
