
module Hecks
  module Generators
    module SQL
    # Hecks::Generators::SQL::SqlMigrationGenerator
    #
    # Generates CREATE TABLE SQL statements from a domain model. Produces one
    # table per aggregate plus join tables for list-type value objects. Part of
    # Generators::SQL, invoked by the CLI `hecks build` command to produce
    # db/schema.sql.
    #
    #   gen = SqlMigrationGenerator.new(domain)
    #   gen.generate  # => "CREATE TABLE pizzas (\n  id VARCHAR(36) PRIMARY KEY,\n  ..."
    #
    class SqlMigrationGenerator
      include HecksTemplating::NamingHelpers
      # Initializes a migration generator for a full domain.
      #
      # @param domain [DomainModel::Structure::Domain] the domain to generate SQL for
      def initialize(domain)
        @domain = domain
      end

      # Generates CREATE TABLE SQL for the entire domain.
      #
      # Produces one table per aggregate with scalar attributes, plus join
      # tables for list-type value objects and entities. Tables are separated
      # by blank lines.
      #
      # @return [String] the complete SQL schema as a string
      def generate
        tables = []

        @domain.aggregates.each do |agg|
          tables << generate_aggregate_table(agg)

          agg.value_objects.each do |vo|
            # Value objects with list attributes get their own join table
            list_attrs = agg.attributes.select { |a| a.list? && a.type.to_s == vo.name }
            unless list_attrs.empty?
              tables << generate_value_object_table(vo, agg)
            end
          end

          agg.entities.each do |ent|
            # Entities with list attributes get their own table (with id column)
            list_attrs = agg.attributes.select { |a| a.list? && a.type.to_s == ent.name }
            unless list_attrs.empty?
              tables << generate_entity_table(ent, agg)
            end
          end
        end

        tables.join("\n\n")
      end

      # Generates a CREATE TABLE statement for an aggregate's main table.
      #
      # Includes an id primary key and all scalar (non-list) attributes.
      #
      # @param agg [DomainModel::Structure::Aggregate] the aggregate
      # @return [String] the CREATE TABLE SQL statement
      def generate_aggregate_table(agg)
        lines = []
        lines << "CREATE TABLE #{table_name(agg.name)} ("
        lines << "  id VARCHAR(36) PRIMARY KEY"

        agg.attributes.each do |attr|
          next if attr.list?
          lines << "  #{attr.name} #{sql_type(attr)},"
        end

        (agg.references || []).each do |ref|
          ref_table = table_name(ref.type)
          lines << "  #{ref.name}_id VARCHAR(36) REFERENCES #{ref_table}(id) ON DELETE SET NULL,"
        end

        # Fix trailing comma on last line before id
        has_cols = agg.attributes.any? { |a| !a.list? } || (agg.references || []).any?
        lines[1] = lines[1] + "," if has_cols

        # Remove trailing comma from last attribute
        lines[-1] = lines[-1].chomp(",")

        lines << ");"
        lines.join("\n")
      end

      # Generates a CREATE TABLE statement for a value object's join table.
      #
      # Includes an id, a foreign key referencing the parent aggregate,
      # and all value object attributes.
      #
      # @param vo [DomainModel::Structure::ValueObject] the value object
      # @param parent_agg [DomainModel::Structure::Aggregate] the parent aggregate
      # @return [String] the CREATE TABLE SQL statement
      def generate_value_object_table(vo, parent_agg)
        generate_child_table(vo, parent_agg)
      end

      # Generates a CREATE TABLE statement for an entity's join table.
      #
      # Similar to value object tables but for entities (which have their own id).
      # Includes an id, a foreign key to the parent aggregate, and all entity attributes.
      #
      # @param ent [DomainModel::Structure::Entity] the entity
      # @param parent_agg [DomainModel::Structure::Aggregate] the parent aggregate
      # @return [String] the CREATE TABLE SQL statement
      def generate_entity_table(ent, parent_agg)
        generate_child_table(ent, parent_agg)
      end

      # Generates a CREATE TABLE statement for a child object (value object or entity).
      #
      # Includes an id, a foreign key referencing the parent aggregate,
      # and all child attributes.
      #
      # @param child [DomainModel::Structure::ValueObject, DomainModel::Structure::Entity]
      # @param parent_agg [DomainModel::Structure::Aggregate] the parent aggregate
      # @return [String] the CREATE TABLE SQL statement
      def generate_child_table(child, parent_agg)
        parent_table = table_name(parent_agg.name)
        child_table = "#{parent_table}_#{table_name(child.name)}"

        lines = []
        lines << "CREATE TABLE #{child_table} ("
        lines << "  id VARCHAR(36) PRIMARY KEY,"
        lines << "  #{domain_snake_name(domain_constant_name(parent_agg.name))}_id VARCHAR(36) NOT NULL REFERENCES #{parent_table}(id),"

        child.attributes.each_with_index do |attr, idx|
          comma = idx < child.attributes.size - 1 ? "," : ""
          lines << "  #{attr.name} #{sql_type(attr)}#{comma}"
        end

        lines << ");"
        lines.join("\n")
      end

      private

      # Maps a domain attribute to its SQL column type.
      #
      # @param attr [DomainModel::Structure::Attribute] the attribute
      # @return [String] the SQL type (e.g., "VARCHAR(255)", "INTEGER")
      def sql_type(attr)
        case attr.type.to_s
        when "String"  then "VARCHAR(255)"
        when "Integer" then "INTEGER"
        when "Float"   then "REAL"
        when "Boolean", "TrueClass", "FalseClass" then "BOOLEAN"
        else "TEXT"
        end
      end

      # Computes the SQL table name for a domain element (underscore + pluralized).
      #
      # @param name [String] the element name (e.g., "Pizza")
      # @return [String] the table name (e.g., "pizzas")
      def table_name(name)
        domain_aggregate_slug(name)
      end
    end
    end
  end
end
