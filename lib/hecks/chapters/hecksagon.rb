# Hecks::Chapters::Hecksagon
#
# Self-describing chapter definition for the hecksagon gem.
# Enumerates every class and module under hecksagon/lib/ as
# aggregates with their key commands, using namespace, inherits,
# includes, and method_name to enable self-hosting.
#
#   domain = Hecks::Chapters::Hecksagon.definition
#   domain.aggregates.map(&:name)
#   # => ["HecksagonBuilder", "GateBuilder", "AclDefinition", ...]
#
require "bluebook"

module Hecks
  module Chapters
    require_paragraphs(__FILE__)

    module Hecksagon
      def self.summary = "Hexagonal architecture wiring DSL for Hecks"

      def self.definition
        Hecks::DSL::DomainBuilder.new("Hecksagon").tap { |b|
          # Entry points — autoload files
          b.entry_point "hecksagon"
          b.entry_point "hecks_persist"
          b.entry_point "hecks_mongodb"

          # --- DSL Builders ---

          b.aggregate "HecksagonBuilder" do
            description "DSL builder for hexagonal architecture wiring: gates, adapters, extensions"
            namespace "Hecksagon::DSL"
            command("AddGate") { attribute :aggregate, String; attribute :role, String }
            command("SetAdapter") { attribute :type, String }
            command "Build"
          end

          b.aggregate "GateBuilder" do
            description "DSL builder for access control gates on aggregates"
            namespace "Hecksagon::DSL"
            command("Allow") { attribute :methods, String }
            command "Build"
          end

          # --- IR Structures ---

          b.aggregate "GateDefinition" do
            description "Immutable IR structure for a gate (access control on an aggregate)"
            namespace "Hecksagon::Structure"
            command("Create") { attribute :aggregate, String; attribute :role, String }
          end

          b.aggregate "AclDefinition" do
            description "Collects translations for an anti-corruption layer"
            namespace "Hecksagon"
            command("Translate") { attribute :entity, String }
          end

          # --- Module Mixins ---

          b.aggregate "DrivenPortRegistry" do
            description "Formalizes adapter registration for driven ports"
            namespace "Hecksagon"
            command("RegisterAdapter") { attribute :name, String; attribute :port, String }
            command("LookupAdapter") { attribute :name, String }
          end

          b.aggregate "ContractValidator" do
            description "Validates that adapters satisfy their driven port contracts at boot time"
            namespace "Hecksagon"
            command "Validate"
          end

          b.aggregate "StrategicDSL" do
            description "Mixin for domain builders adding shared kernels, ACLs, published events"
            namespace "Hecksagon"
            command "SharedKernel"
            command("UseKernel") { attribute :name, String }
            command("AntiCorruptionLayer") { attribute :name, String }
          end

          b.aggregate "ExtensionsDSL" do
            description "Mixin for domain builders declaring driving and driven ports"
            namespace "Hecksagon"
            command("DrivingPort") { attribute :name, String }
            command("DrivenPort") { attribute :name, String }
          end

          b.aggregate "DomainMixin" do
            description "Extends Domain IR objects with hexagonal accessors for ports and kernels"
            namespace "Hecksagon"
            command "Apply"
          end

          # --- SQL Persistence ---

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

          b.aggregate "DatabaseConnection" do
            description "Connects to databases via Sequel: MySQL, Postgres, SQLite, URLs"
            namespace "Hecks::Boot"
            command("Connect") { attribute :url, String }
          end

          # --- MongoDB ---

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

          # --- Extensions ---

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

          # --- CLI ---

          b.aggregate "Migrations" do
            description "CLI command for generating SQL migrations from domain changes"
            command "GenerateMigrations"
          end
          Chapters.define_paragraphs(Hecksagon, b)
        }.build
      end
    end
  end
end
