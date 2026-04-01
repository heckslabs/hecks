require "fileutils"
require_relative "sql_helpers"

module Hecks
  module Migrations
    module Strategies
      # Hecks::Migrations::Strategies::SqlStrategy
      #
      # Generates SQL migration files from domain changes. Produces ALTER TABLE
      # statements for attribute changes and CREATE TABLE for new aggregates.
      # Supports NOT NULL (from presence validations), UNIQUE (from uniqueness
      # validations), DEFAULT values, foreign key cascading, and indexes.
      # Output goes to db/hecks_migrate/ to avoid conflicts with ActiveRecord.
      #
      #   strategy = SqlStrategy.new(output_dir: ".")
      #   strategy.generate(changes)
      #
      class SqlStrategy < MigrationStrategy
        include HecksTemplating::NamingHelpers
      include SqlHelpers

      # Generates SQL migration content from a list of domain changes.
      #
      # Processes each change and produces the appropriate SQL statement:
      # - :add_aggregate -> CREATE TABLE with all columns, indexes, and join tables
      # - :remove_aggregate -> DROP TABLE
      # - :add_attribute -> ALTER TABLE ADD COLUMN
      # - :remove_attribute -> ALTER TABLE DROP COLUMN
      # - :add_value_object -> CREATE TABLE for join table
      # - :remove_value_object -> DROP TABLE for join table
      #
      # @param changes [Array<Migrations::Change>] the domain changes to migrate
      # @return [String, nil] the SQL migration content, or nil if no changes
      def generate(changes)
        lines = []

        changes.each do |change|
          case change.kind
          when :add_aggregate
            lines << generate_create_table(change)
          when :remove_aggregate
            lines << "DROP TABLE IF EXISTS #{table_name(change.aggregate)};"
          when :add_attribute
            lines << generate_add_column(change)
          when :remove_attribute
            lines << "ALTER TABLE #{table_name(change.aggregate)} DROP COLUMN #{change.details[:name]};"
          when :add_value_object
            lines << generate_create_join_table(change)
          when :remove_value_object
            lines << "DROP TABLE IF EXISTS #{join_table_name(change.aggregate, change.details[:name])};"
          when :add_reference
            ref = change.details[:reference]
            lines << "ALTER TABLE #{table_name(change.aggregate)} ADD COLUMN #{reference_column_def(ref)};"
          when :remove_reference
            ref = change.details[:reference]
            lines << "ALTER TABLE #{table_name(change.aggregate)} DROP COLUMN #{reference_column_name(ref)};"
          end
        end

        return nil if lines.empty?
        lines.compact.join("\n\n") + "\n"
      end

      # Returns the migration file path with a timestamp prefix.
      #
      # @return [String] the file path (e.g., "db/hecks_migrate/20260326120000_hecks_migration.sql")
      def file_path
        timestamp = Time.now.strftime("%Y%m%d%H%M%S")
        "db/hecks_migrate/#{timestamp}_hecks_migration.sql"
      end

      private

      # Generates a CREATE TABLE statement for a new aggregate.
      #
      # Includes id primary key, all scalar attributes with NOT NULL/UNIQUE/DEFAULT
      # constraints from validations, created_at/updated_at timestamps,
      # auto-indexes on reference columns, and join tables for list value objects.
      #
      # @param change [Migrations::Change] the :add_aggregate change
      # @return [String] the complete SQL for creating the table and related objects
      def generate_create_table(change)
        tables = []
        presence_fields = presence_fields_from(change.details[:validations])
        unique_fields = unique_fields_from(change.details[:validations])

        cols = ["  id VARCHAR(36) PRIMARY KEY"]
        change.details[:attributes].each do |attr|
          next if attr.list?
          cols << "  #{column_def(attr, presence_fields, unique_fields)}"
        end
        (change.details[:references] || []).each do |ref|
          cols << "  #{reference_column_def(ref)}"
        end
        cols << "  created_at DATETIME"
        cols << "  updated_at DATETIME"
        tables << "CREATE TABLE #{table_name(change.aggregate)} (\n#{cols.join(",\n")}\n);"

        # Generate indexes
        indexes_sql = generate_indexes_for_table(change)
        tables << indexes_sql if indexes_sql

        # Generate join tables for list value objects
        (change.details[:value_objects] || []).each do |vo|
          list_attr = change.details[:attributes].find { |a| a.list? && a.type.to_s == vo.name }
          next unless list_attr
          tables << generate_create_join_table_from_vo(change.aggregate, vo)
        end

        tables.compact.join("\n\n")
      end

      # Generates a column definition string with type and constraints.
      #
      # @param attr [DomainModel::Structure::Attribute] the attribute
      # @param presence_fields [Array<Symbol>] fields requiring NOT NULL
      # @param unique_fields [Array<Symbol>] fields requiring UNIQUE
      # @return [String] the column definition (e.g., "name VARCHAR(255) NOT NULL")
      def column_def(attr, presence_fields = [], unique_fields = [])
        parts = [attr.name.to_s, sql_type(attr)]
        parts << "NOT NULL" if presence_fields.include?(attr.name.to_sym)
        parts << "UNIQUE" if unique_fields.include?(attr.name.to_sym)
        parts << "DEFAULT #{sql_literal(attr.default)}" unless attr.default.nil?
        parts.join(" ")
      end

      # Generates a column definition for a reference (foreign key).
      #
      # @param ref [DomainModel::Structure::Reference] the reference
      # @return [String] the column definition (e.g., "team_id VARCHAR(36) REFERENCES teams(id)")
      def reference_column_def(ref)
        col = reference_column_name(ref)
        ref_table = domain_aggregate_slug(ref.type)
        "#{col} VARCHAR(36) REFERENCES #{ref_table}(id) ON DELETE SET NULL"
      end

      # Generates a CREATE TABLE for a value object's join table from a VO struct.
      #
      # @param aggregate_name [String] the parent aggregate name
      # @param vo [DomainModel::Structure::ValueObject] the value object
      # @return [String] the CREATE TABLE SQL statement
      def generate_create_join_table_from_vo(aggregate_name, vo)
        parent_table = table_name(aggregate_name)
        jt = join_table_name(aggregate_name, vo.name)
        parent_fk = "#{domain_snake_name(aggregate_name)}_id"

        cols = [
          "  id VARCHAR(36) PRIMARY KEY",
          "  #{parent_fk} VARCHAR(36) NOT NULL REFERENCES #{parent_table}(id) ON DELETE CASCADE"
        ]
        vo.attributes.each do |attr|
          cols << "  #{attr.name} #{sql_type(attr)}"
        end

        "CREATE TABLE #{jt} (\n#{cols.join(",\n")}\n);"
      end

      # Generates an ALTER TABLE ADD COLUMN statement for a new attribute.
      #
      # Skips list-type attributes (handled by join tables). Includes NOT NULL,
      # UNIQUE, DEFAULT, and foreign key constraints based on change details.
      #
      # @param change [Migrations::Change] the :add_attribute change
      # @return [String, nil] the ALTER TABLE SQL, or nil for list attributes
      def generate_add_column(change)
        d = change.details
        return nil if d[:list]

        type = sql_type_for(d[:type])
        parts = ["#{d[:name]} #{type}"]
        parts << "NOT NULL" if d[:presence]
        parts << "UNIQUE" if d[:uniqueness]
        parts << "DEFAULT #{sql_literal(d[:default])}" if d[:default]

        "ALTER TABLE #{table_name(change.aggregate)} ADD COLUMN #{parts.join(" ")};"
      end

      # Generates a CREATE TABLE for a value object's join table from a change.
      #
      # @param change [Migrations::Change] the :add_value_object change
      # @return [String] the CREATE TABLE SQL statement
      def generate_create_join_table(change)
        parent_table = table_name(change.aggregate)
        vo_name = change.details[:name]
        jt = join_table_name(change.aggregate, vo_name)
        parent_fk = "#{domain_snake_name(change.aggregate)}_id"

        cols = [
          "  id VARCHAR(36) PRIMARY KEY",
          "  #{parent_fk} VARCHAR(36) NOT NULL REFERENCES #{parent_table}(id) ON DELETE CASCADE"
        ]
        change.details[:attributes].each do |attr|
          cols << "  #{attr.name} #{sql_type(attr)}"
        end

        "CREATE TABLE #{jt} (\n#{cols.join(",\n")}\n);"
      end

      # Generates CREATE INDEX statements for reference columns on a new table.
      #
      # Automatically indexes all reference (foreign key) attributes for
      # query performance.
      #
      # @param change [Migrations::Change] the :add_aggregate change
      # @return [String, nil] the CREATE INDEX statements, or nil if no references
      def generate_indexes_for_table(change)
        agg_name = change.aggregate
        refs = change.details[:references] || []
        return nil if refs.empty?
        refs.map do |ref|
          col = reference_column_name(ref)
          idx = index_name(agg_name, [col])
          "CREATE INDEX #{idx} ON #{table_name(agg_name)}(#{col});"
        end.join("\n")
      end

      end
    end
  end
end
