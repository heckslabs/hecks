# Hecks::Chapters::Hecksagon::DatabaseParagraph
#
# Paragraph covering database connectivity and persistence extensions:
# connection pooling, MongoDB adapter/boot, and SQL dialect extensions.
#
#   Hecks::Chapters::Hecksagon::DatabaseParagraph.define(builder)
#
module Hecks
  module Chapters
    module Hecksagon
      module DatabaseParagraph
        def self.define(b)
          b.aggregate "DatabaseConnection" do
            description "Connects to databases via Sequel: MySQL, Postgres, SQLite, URLs"
            namespace "Hecks::Boot"
            command("Connect") { attribute :url, String }
          end

          b.aggregate "MongoAdapterGenerator" do
            description "Generates MongoDB repository adapter classes for each aggregate"
            namespace "Hecks::Generators::Mongo"
            inherits "Hecks::Generator"
            command "Generate"
          end

          b.aggregate "MongoBoot" do
            description "MongoDB adapter lifecycle: connect, generate repos, return adapters"
            namespace "Hecks::Boot"
            command "Setup"
          end

          b.aggregate "HecksMysql" do
            description "MySQL persistence extension, auto-wires SQL adapters via Sequel mysql2"
            command "Boot"
          end

          b.aggregate "HecksPostgres" do
            description "PostgreSQL persistence extension, auto-wires SQL adapters via Sequel pg"
            command "Boot"
          end

          b.aggregate "HecksSqlite" do
            description "SQLite persistence extension, auto-wires in-memory SQL adapters"
            command "Boot"
          end
        end
      end
    end
  end
end
