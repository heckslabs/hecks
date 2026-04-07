# Hecks::Chapters::Hecksagon
#
# Self-describing chapter definition for the hecksagon gem.
# Enumerates every class and module under hecksagon/lib/ as
# aggregates with their key commands.
#
#   domain = Hecks::Chapters::Hecksagon.definition
#   domain.aggregates.map(&:name)
#   # => ["HecksagonBuilder", "GateBuilder", "AclBuilder", ...]
#
require "bluebook"

module Hecks
  module Chapters
    module Hecksagon
      def self.definition
        Hecks::DSL::DomainBuilder.new("Hecksagon").tap { |b|
          b.aggregate "HecksagonBuilder" do
            description "DSL builder for hexagonal architecture wiring: gates, adapters, extensions"
            command "AddGate" do
              attribute :aggregate, String
              attribute :role, String
            end
            command "SetAdapter" do
              attribute :type, String
            end
            command "Build"
          end

          b.aggregate "GateBuilder" do
            description "DSL builder for access control gates on aggregates"
            command "Allow" do
              attribute :methods, String
            end
            command "Build"
          end

          b.aggregate "GateDefinition" do
            description "Immutable IR structure for a gate (access control on an aggregate)"
            command "Create" do
              attribute :aggregate, String
              attribute :role, String
            end
          end

          b.aggregate "AclDefinition" do
            description "Collects translations for an anti-corruption layer"
            command "Translate" do
              attribute :entity, String
            end
          end

          b.aggregate "DrivenPortRegistry" do
            description "Formalizes adapter registration for driven ports"
            command "RegisterAdapter" do
              attribute :name, String
              attribute :port, String
            end
            command "LookupAdapter" do
              attribute :name, String
            end
          end

          b.aggregate "ContractValidator" do
            description "Validates that adapters satisfy their driven port contracts at boot time"
            command "Validate"
          end

          b.aggregate "StrategicDSL" do
            description "Mixin for domain builders adding shared kernels, ACLs, published events"
            command "SharedKernel"
            command "UseKernel" do
              attribute :name, String
            end
            command "AntiCorruptionLayer" do
              attribute :name, String
            end
          end

          b.aggregate "ExtensionsDSL" do
            description "Mixin for domain builders declaring driving and driven ports"
            command "DrivingPort" do
              attribute :name, String
            end
            command "DrivenPort" do
              attribute :name, String
            end
          end

          b.aggregate "DomainMixin" do
            description "Extends Domain IR objects with hexagonal accessors for ports and kernels"
            command "Apply"
          end

          b.aggregate "SqlAdapterGenerator" do
            description "Generates Sequel-based repository adapter classes for each aggregate"
            command "Generate"
          end

          b.aggregate "SqlBuilder" do
            description "Mixin with Sequel-based generation helpers for insert, update, delete"
            command "BuildInsert"
            command "BuildUpdate"
          end

          b.aggregate "SqlMigrationGenerator" do
            description "Generates CREATE TABLE SQL statements from a domain model"
            command "Generate"
          end

          b.aggregate "SqlStrategy" do
            description "Generates SQL migration files from domain changes with ALTER TABLE support"
            command "GenerateMigration"
          end

          b.aggregate "SqlHelpers" do
            description "Shared helpers for SQL migration: type mapping, naming, literal quoting"
            command "MapType" do
              attribute :ruby_type, String
            end
          end

          b.aggregate "SqlSetup" do
            description "Generates and evals SQL adapter classes at boot time for Hecks.configure"
            command "Setup"
          end

          b.aggregate "SqlBoot" do
            description "SQL adapter lifecycle: connect, generate repos, create tables"
            command "Setup"
          end

          b.aggregate "DatabaseConnection" do
            description "Connects to databases via Sequel: MySQL, Postgres, SQLite, URLs"
            command "Connect" do
              attribute :url, String
            end
          end

          b.aggregate "MongoAdapterGenerator" do
            description "Generates MongoDB repository adapter classes for each aggregate"
            command "Generate"
          end

          b.aggregate "MongoBoot" do
            description "MongoDB adapter lifecycle: connect, generate repos, return adapters"
            command "Setup"
          end

          b.aggregate "HecksCqrs" do
            description "CQRS support: named persistence connections for read/write separation"
            command "Enable"
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

          b.aggregate "HecksTransactions" do
            description "Command bus middleware wrapping execution in database transactions"
            command "Wrap"
          end

          b.aggregate "Migrations" do
            description "CLI command for generating SQL migrations from domain changes"
            command "GenerateMigrations"
          end
        }.build
      end
    end
  end
end
