# Hecks::Chapters::Persist
#
# Self-describing chapter for the HecksPersist component. Covers SQL
# persistence via Sequel: database connection, adapter generation,
# schema generation, migration strategy, and boot wiring.
#
#   domain = Hecks::Chapters::Persist.definition
#   domain.aggregates.map(&:name)
#
require "bluebook"

module Hecks
  module Chapters
    module Persist
      def self.definition
        DSL::DomainBuilder.new("Persist").tap { |b|
          b.aggregate "DatabaseConnection" do
            description "Connects to databases via Sequel, supports MySQL/Postgres/SQLite and Rails auto-detection"
            command "Connect" do
              attribute :url, String
            end
            command "ConnectByType" do
              attribute :database, String
              attribute :host, String
            end
            command "ConnectFromRails"
          end

          b.aggregate "SqlAdapterGenerator" do
            description "Generates Sequel-based repository adapter classes from aggregate IR"
            command "Generate" do
              attribute :aggregate_name, String
              attribute :domain_module, String
            end
          end

          b.aggregate "SqlBuilder" do
            description "Mixin with Sequel-based generation helpers for insert, update, build, and delete methods"
            command "InsertLines"
            command "UpdateLines"
            command "BuildLines"
            command "DeleteLines"
          end

          b.aggregate "SqlMigrationGenerator" do
            description "Generates CREATE TABLE SQL statements from a domain model"
            command "Generate" do
              attribute :domain_name, String
            end
          end

          b.aggregate "SqlStrategy" do
            description "Generates SQL migration files from domain changes with ALTER TABLE and CREATE TABLE"
            command "Generate" do
              attribute :changes, String
            end
          end

          b.aggregate "SqlHelpers" do
            description "Shared helpers for SQL type mapping, naming conventions, and literal quoting"
            command "SqlType" do
              attribute :attribute_type, String
            end
            command "TableName" do
              attribute :aggregate_name, String
            end
          end

          b.aggregate "SqlBoot" do
            description "Handles SQL adapter lifecycle: connect, generate adapters, create tables at boot"
            command "Boot" do
              attribute :domain_name, String
            end
          end

          b.aggregate "SqlSetup" do
            description "Generates and evals SQL adapter classes for each aggregate during Hecks.configure"
            command "Setup" do
              attribute :domain_name, String
            end
          end
        }.build
      end
    end
  end
end
