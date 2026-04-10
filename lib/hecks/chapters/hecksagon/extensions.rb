# Hecks::Chapters::Hecksagon::ExtensionsParagraph
#
# Paragraph covering Hecksagon runtime extensions: CQRS, transactions,
# and the CLI migrations command.
#
#   Hecks::Chapters::Hecksagon::ExtensionsParagraph.define(builder)
#
module Hecks
  module Chapters
    module Hecksagon
      module ExtensionsParagraph
        def self.define(b)
          b.aggregate "HecksCqrs" do
            description "CQRS support: named persistence connections for read/write separation"
            command "Enable"
          end

          b.aggregate "HecksTransactions" do
            description "Command bus middleware wrapping execution in database transactions"
            command "Wrap"
          end

          b.aggregate "Migrations" do
            description "CLI command for generating SQL migrations from domain changes"
            command "GenerateMigrations"
          end
        end
      end
    end
  end
end
