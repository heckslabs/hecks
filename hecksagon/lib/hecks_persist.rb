# = HecksPersist
#
# SQL persistence layer for Hecks domains. Provides Sequel-based repository
# adapters, SQL schema generation, and migration file generation. Supports
# SQLite, PostgreSQL, and MySQL via the Sequel gem.
#
# This module registers autoloads for three generator/strategy classes:
#
# - {Hecks::Generators::SQL::SqlAdapterGenerator} -- Generates Sequel-based
#   repository adapter classes for each aggregate
# - {Hecks::Generators::SQL::SqlBuilder} -- Builds SQL CREATE TABLE statements
#   from domain attribute definitions
# - {Hecks::Generators::SQL::SqlMigrationGenerator} -- Generates Sequel
#   migration files from domain diffs
# - {Hecks::Migrations::Strategies::SqlStrategy} -- Executes SQL migrations
#   against a live database connection
#
# == Usage
#
#   require "hecks_persist"
#   app = Hecks.boot(__dir__, adapter: :sqlite)
#
# This is a separate entry point (future gem: +hecks_persist+) to keep
# Sequel and database dependencies isolated from the core framework.
#
module Hecks
  module Generators
    # = Hecks::Generators::SQL
    #
    # Namespace for SQL-related code generators. Contains the adapter
    # generator (produces repository classes), the SQL builder (produces
    # DDL statements), and the migration generator (produces versioned
    # migration files).
    module SQL
      autoload :SqlAdapterGenerator,   "hecks_persist/sql_adapter_generator"
      autoload :SqlBuilder,            "hecks_persist/sql_builder"
      autoload :SqlMigrationGenerator, "hecks_persist/sql_migration_generator"
    end
  end

  module Boot
    autoload :SqlBoot,            "hecks_persist/sql_boot"
    autoload :DatabaseConnection, "hecks_persist/database_connection"
  end

  module Migrations
    module Strategies
      # = Hecks::Migrations::Strategies::SqlStrategy
      #
      # Strategy for applying domain migrations to a SQL database via Sequel.
      # Reads migration files from +db/hecks_migrate/+ and executes them
      # in order against the configured database connection.
      autoload :SqlStrategy, "hecks_persist/sql_strategy"
      autoload :SqlHelpers, "hecks_persist/sql_helpers"
    end
  end
end
