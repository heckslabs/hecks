module Hecks
  module Migrations
    # Hecks::Migrations::MigrationRunner
    #
    # Executes pending SQL migration files from db/hecks_migrate/ against a
    # database connection. Tracks applied migrations in a hecks_schema_migrations
    # table to avoid re-running them. Wraps each migration in a transaction
    # when the connection supports it.
    #
    # The connection is duck-typed -- any object responding to #execute(sql).
    # In Rails, pass ActiveRecord::Base.connection. For SQLite, wrap the db.
    #
    #   runner = MigrationRunner.new(connection: ActiveRecord::Base.connection)
    #   runner.pending   # => ["20260321120000_hecks_migration.sql"]
    #   runner.run_all   # applies pending migrations
    #
    class MigrationRunner

    # Name of the tracking table that records which migrations have been applied.
    TRACKING_TABLE = "hecks_schema_migrations"

    # Create a new migration runner. Automatically creates the tracking table
    # if it does not already exist.
    #
    # @param connection [#execute] a database connection object that responds
    #   to #execute(sql). Optionally responds to #transaction for wrapping
    #   migrations in transactions.
    # @param migration_dir [String] directory containing .sql migration files
    #   (default "db/hecks_migrate")
    def initialize(connection:, migration_dir: "db/hecks_migrate")
      @connection = connection
      @migration_dir = migration_dir
      setup_tracking_table
    end

    # List migration files that have not yet been applied to the database.
    # Compares all .sql files in the migration directory against the
    # tracking table.
    #
    # @return [Array<String>] full paths to pending migration files, sorted
    #   alphabetically (which sorts chronologically given timestamped names)
    def pending
      applied = applied_versions
      all_migrations.reject { |f| applied.include?(File.basename(f)) }
    end

    # Execute all pending migrations in order. Each migration is wrapped in
    # a transaction if the connection supports it. Records each successful
    # migration in the tracking table. Raises on failure with the migration
    # name and error message.
    #
    # @return [Array<String>] basenames of successfully applied migration files
    # @raise [Hecks::MigrationError] if any migration fails to execute
    def run_all
      results = []
      pending.each do |file|
        name = File.basename(file)
        begin
          execute_migration(file)
          record_migration(name)
          results << name
        rescue => e
          raise Hecks::MigrationError, "Migration #{name} failed: #{e.message}"
        end
      end
      results
    end

    private

    # Execute a single migration file. Reads the SQL content and executes
    # it, optionally wrapped in a transaction.
    #
    # @param file [String] full path to the .sql migration file
    # @return [void]
    def execute_migration(file)
      sql = File.read(file)
      if @connection.respond_to?(:transaction)
        @connection.transaction { execute_statements(sql) }
      else
        execute_statements(sql)
      end
    end

    # Split a SQL string on semicolons and execute each statement individually.
    # Skips empty statements after stripping whitespace.
    #
    # @param sql [String] raw SQL content potentially containing multiple statements
    # @return [void]
    def execute_statements(sql)
      sql.split(";").each do |stmt|
        stmt = stmt.strip
        @connection.execute(stmt + ";") unless stmt.empty?
      end
    end

    # Create the tracking table if it does not already exist.
    #
    # @return [void]
    def setup_tracking_table
      @connection.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS #{TRACKING_TABLE} (
          version VARCHAR(255) PRIMARY KEY
        );
      SQL
    end

    # Query the tracking table for all previously applied migration versions.
    #
    # @return [Array<String>] filenames of applied migrations
    def applied_versions
      rows = @connection.execute("SELECT version FROM #{TRACKING_TABLE};")
      rows.map { |r| r.is_a?(Hash) ? r["version"] : r[0] }
    end

    # Record a migration as applied in the tracking table.
    #
    # @param filename [String] the migration filename to record
    # @return [void]
    def record_migration(filename)
      escaped = filename.gsub("'", "''")
      @connection.execute(
        "INSERT INTO #{TRACKING_TABLE} (version) VALUES ('#{escaped}');"
      )
    end

    # List all .sql migration files in the migration directory, sorted
    # alphabetically.
    #
    # @return [Array<String>] full paths to migration files, or empty array
    #   if the directory does not exist
    def all_migrations
      return [] unless Dir.exist?(@migration_dir)

      Dir.glob(File.join(@migration_dir, "*.sql")).sort
    end
    end
  end
end
