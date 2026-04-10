# Hecks::Chapters::Hecksagon::SqlParagraph
#
# Paragraph covering SQL persistence: generator, builder mixin,
# migration generator, migration strategy, helpers, setup, and boot.
#
#   Hecks::Chapters::Hecksagon::SqlParagraph.define(builder)
#
module Hecks
  module Chapters
    module Hecksagon
      module SqlParagraph
        def self.define(b)
          b.aggregate "SqlAdapterGenerator" do
            description "Generates Sequel-based repository adapter classes for each aggregate"
            namespace "Hecks::Generators::SQL"
            inherits "Hecks::Generator"
            includes "SqlBuilder"
            command "Generate"
          end

          b.aggregate "SqlBuilder" do
            description "Mixin with Sequel-based generation helpers for insert, update, delete"
            namespace "Hecks::Generators::SQL"
            command("BuildInsert") { method_name "insert_lines" }
            command("BuildUpdate") { method_name "update_lines" }
          end

          b.aggregate "SqlMigrationGenerator" do
            description "Generates CREATE TABLE SQL statements from a domain model"
            namespace "Hecks::Generators::SQL"
            inherits "Hecks::Generator"
            command "Generate"
          end

          b.aggregate "SqlStrategy" do
            description "Generates SQL migration files from domain changes with ALTER TABLE support"
            namespace "Hecks::Migrations::Strategies"
            includes "SqlHelpers"
            command("GenerateMigration") { method_name "generate" }
          end

          b.aggregate "SqlHelpers" do
            description "Shared helpers for SQL migration: type mapping, naming, literal quoting"
            namespace "Hecks::Migrations::Strategies"
            command("MapType") { method_name "sql_type_for"; attribute :ruby_type, String }
          end

          b.aggregate "SqlSetup" do
            description "Generates and evals SQL adapter classes at boot time for Hecks.configure"
            namespace "Hecks::Configuration"
            command "Setup"
          end

          b.aggregate "SqlBoot" do
            description "SQL adapter lifecycle: connect, generate repos, create tables"
            namespace "Hecks::Boot"
            command "Setup"
          end
        end
      end
    end
  end
end
