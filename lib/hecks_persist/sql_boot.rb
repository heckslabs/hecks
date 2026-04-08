
module Hecks
  module Boot
    # Hecks::Boot::SqlBoot
    #
    # Handles SQL adapter lifecycle: connects to a database via Sequel,
    # generates SQL repository classes for each aggregate, creates tables
    # from the domain IR, and returns adapter instances keyed by aggregate name.
    # Part of Boot, consumed by Hecks.boot when adapter: :sqlite (or similar).
    #
    #   adapters = SqlBoot.setup(domain, db)
    #   # => { "Pizza" => #<PizzasDomain::Adapters::PizzaSqlRepository>, ... }
    #
    module SqlBoot
      extend HecksTemplating::NamingHelpers
      # Maps domain type names to Sequel column types for table creation.
      TYPE_MAP = {
        "String"  => String,
        "Integer" => Integer,
        "Float"   => Float,
        "Boolean" => :boolean,
        "JSON"    => String
      }.freeze

      module_function

      # Connects to a database based on adapter configuration.
      #
      # @param adapter [Symbol, Hash] :sqlite for in-memory SQLite, or a Hash
      #   with :type, :database, and other connection options
      # @return [Sequel::Database] the database connection
      # @raise [ArgumentError] if the adapter type is unknown
      # @raise [LoadError] if the sequel gem is not installed
      def connect(adapter)
        require_sequel!
        config = normalize_config(adapter)

        case config[:type]
        when :sqlite
          config[:database] ? Sequel.sqlite(config[:database]) : Sequel.sqlite
        when :postgres
          Sequel.connect(config)
        when :mysql, :mysql2
          Sequel.connect(config)
        else
          raise ArgumentError, "Unknown SQL adapter type: #{config[:type]}"
        end
      end

      # Performs full SQL setup: generates adapter classes, creates tables,
      # and returns instantiated repository objects.
      #
      # @param domain [BluebookModel::Structure::Domain] the domain model
      # @param db [Sequel::Database] the database connection
      # @return [Hash<String, Object>] adapter instances keyed by aggregate name
      def setup(domain, db)
        mod_name = domain_module_name(domain.name)
        generate_adapters(domain, mod_name)
        create_tables(domain, db)
        instantiate_adapters(domain, db, mod_name)
      end

      # Generates and evals SQL repository classes for each aggregate.
      #
      # @param domain [BluebookModel::Structure::Domain] the domain model
      # @param mod_name [String] the domain module name (e.g., "PizzasDomain")
      # @return [void]
      def generate_adapters(domain, mod_name)
        domain.aggregates.each do |agg|
          gen = Generators::SQL::SqlAdapterGenerator.new(agg, domain_module: mod_name)
          eval(gen.generate, TOPLEVEL_BINDING, "(sql_adapter:#{agg.name})", 1)
        end
      end

      # Creates database tables for all aggregates (idempotent -- skips existing).
      #
      # @param domain [BluebookModel::Structure::Domain] the domain model
      # @param db [Sequel::Database] the database connection
      # @return [void]
      def create_tables(domain, db)
        domain.aggregates.each do |agg|
          create_aggregate_table(agg, db)
          create_vo_join_tables(agg, db)
        end
      end

      # Instantiates SQL repository objects for all aggregates.
      #
      # @param domain [BluebookModel::Structure::Domain] the domain model
      # @param db [Sequel::Database] the database connection
      # @param mod_name [String] the domain module name
      # @return [Hash<String, Object>] repository instances keyed by aggregate name
      def instantiate_adapters(domain, db, mod_name)
        mod = Object.const_get(mod_name)
        adapters = {}
        domain.aggregates.each do |agg|
          safe_name = domain_constant_name(agg.name)
          repo_class = mod::Adapters.const_get("#{safe_name}SqlRepository")
          adapters[agg.name] = repo_class.new(db)
        end
        adapters
      end

      # Creates the main table for an aggregate from its IR attributes.
      #
      # Includes an id primary key, all scalar attributes, and created_at/updated_at
      # timestamps. Skips if the table already exists.
      #
      # @param agg [BluebookModel::Structure::Aggregate] the aggregate
      # @param db [Sequel::Database] the database connection
      # @return [void]
      def create_aggregate_table(agg, db)
        tbl = table_name_for(agg)
        return if db.table_exists?(tbl)

        cols = agg.attributes.reject(&:list?).map { |a| [a.name, sequel_type(a)] }
        ref_cols = (agg.references || []).map { |r| [:"#{r.name}_id", String] }
        db.create_table(tbl) do
          String :id, primary_key: true, size: 36
          cols.each { |name, type| column name, type }
          ref_cols.each { |name, type| column name, type }
          String :created_at
          String :updated_at
        end
      end

      # Creates join tables for list-type value objects on an aggregate.
      #
      # Each join table has an id, a foreign key to the parent aggregate,
      # and columns for all value object attributes.
      #
      # @param agg [BluebookModel::Structure::Aggregate] the aggregate
      # @param db [Sequel::Database] the database connection
      # @return [void]
      def create_vo_join_tables(agg, db)
        agg_table = table_name_for(agg)
        agg_snake = domain_snake_name(domain_constant_name(agg.name))

        list_vos(agg).each do |vo, _list_attr|
          vo_table = :"#{agg_table}_#{domain_snake_name(vo.name)}s"
          next if db.table_exists?(vo_table)

          fk_name = :"#{agg_snake}_id"
          vo_cols = vo.attributes.map { |a| [a.name, sequel_type(a)] }
          db.create_table(vo_table) do
            String :id, primary_key: true, size: 36
            String fk_name, null: false
            vo_cols.each { |name, type| column name, type }
          end
        end
      end

      # Returns pairs of [value_object, list_attribute] for list-type VOs.
      #
      # @param agg [BluebookModel::Structure::Aggregate] the aggregate
      # @return [Array<Array(ValueObject, Attribute)>] pairs of VO and its list attribute
      def list_vos(agg)
        agg.value_objects.filter_map do |vo|
          list_attr = agg.attributes.find { |a| a.list? && a.type.to_s == vo.name }
          [vo, list_attr] if list_attr
        end
      end

      # Computes the table name for an aggregate (underscore + pluralize).
      #
      # @param agg [BluebookModel::Structure::Aggregate] the aggregate
      # @return [Symbol] the table name as a symbol (e.g., :pizzas)
      def table_name_for(agg)
        domain_aggregate_slug(agg.name).to_sym
      end

      # Maps a domain attribute to a Sequel column type.
      #
      # @param attr [BluebookModel::Structure::Attribute] the attribute
      # @return [Class, Symbol] the Sequel column type
      def sequel_type(attr)
        TYPE_MAP.fetch(attr.type.to_s, String)
      end

      # Normalizes adapter config to a Hash with a :type key.
      #
      # @param adapter [Symbol, Hash] the adapter configuration
      # @return [Hash] normalized config hash
      # @raise [ArgumentError] if adapter is neither Symbol nor Hash
      def normalize_config(adapter)
        case adapter
        when Symbol then { type: adapter }
        when Hash   then adapter
        else raise ArgumentError, "adapter must be a Symbol or Hash, got #{adapter.class}"
        end
      end

      # Requires the sequel gem, raising a helpful error if missing.
      #
      # @return [void]
      # @raise [LoadError] with installation instructions
      def require_sequel!
        require "sequel"
      rescue LoadError
        raise LoadError,
          "The sequel gem is required for SQL adapters. " \
          "Add gem \"sequel\" and gem \"sqlite3\" (or your DB driver) to your Gemfile."
      end
    end
  end
end
