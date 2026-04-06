  # Hecks::Migrations
  #
  # Schema migration infrastructure: diff detection, snapshot tracking,
  # strategy dispatch, and migration execution. This is the parent module
  # that autoloads the four core migration classes and the Strategies
  # namespace for adapter-specific generators.
  #
  # Migration flow:
  # 1. DomainSnapshot loads the previous domain state from disk
  # 2. DomainDiff compares old and new domains, producing Change objects
  # 3. MigrationStrategy dispatches changes to registered strategies (e.g., SQL)
  # 4. MigrationRunner executes the generated migration files against a database
  #
  #   changes = Migrations::DomainDiff.call(old_domain, new_domain)
  #   Migrations::MigrationStrategy.run_all(changes)
  #
module Hecks
  module Migrations
    autoload :DomainDiff,       "hecks/domain/migrations/domain_diff"
    autoload :DomainSnapshot,   "hecks/domain/migrations/domain_snapshot"
    autoload :MigrationStrategy, "hecks/domain/migrations/migration_strategy"
    autoload :MigrationRunner,  "hecks/domain/migrations/migration_runner"

    # Namespace for adapter-specific migration strategies. Each strategy
    # knows how to generate migration files for its storage backend
    # (e.g., SQL DDL for relational databases).
    module Strategies
      autoload :SqlStrategy, "hecks_persist/sql_strategy"
    end
  end
end
