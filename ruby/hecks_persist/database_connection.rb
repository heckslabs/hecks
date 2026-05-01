module Hecks
  class Configuration
    # Hecks::Configuration::DatabaseConnection
    #
    # Connects to databases via Sequel. Supports MySQL, Postgres, SQLite,
    # connection URLs, and auto-detection from Rails database config.
    #
    #   adapter :sql, database: :mysql, host: "localhost", name: "pizzas"
    #   adapter :sql, url: "postgres://user:pass@host/db"
    #   adapter :sql  # defaults to SQLite in-memory
    #
    module DatabaseConnection
      private

      # Connects to a database based on the adapter options.
      #
      # Resolution order:
      # 1. If :url is provided, connects directly via Sequel.connect
      # 2. If :database type is provided, delegates to connect_by_type
      # 3. If Rails is defined, auto-detects from Rails database config
      # 4. Falls back to in-memory SQLite
      #
      # @return [Sequel::Database] the database connection
      def connect_database
        require "sequel"

        if @adapter_options[:url]
          Sequel.connect(@adapter_options[:url])
        elsif @adapter_options[:database]
          connect_by_type(@adapter_options)
        elsif defined?(::Rails)
          connect_from_rails
        else
          Sequel.sqlite
        end
      end

      # Connects to a specific database type using Sequel.
      #
      # @param opts [Hash] connection options with :database (Symbol), :host,
      #   :user, :password, and :name keys
      # @return [Sequel::Database] the database connection
      # @raise [RuntimeError] if the database type is not :sqlite, :mysql, or :postgres
      def connect_by_type(opts)
        case opts[:database]
        when :mysql
          Sequel.connect(adapter: :mysql2, host: opts[:host] || "localhost",
            user: opts[:user] || "root", password: opts[:password], database: opts[:name])
        when :postgres
          Sequel.connect(adapter: :postgres, host: opts[:host] || "localhost",
            user: opts[:user], password: opts[:password], database: opts[:name])
        when :sqlite
          Sequel.sqlite(opts[:name])
        else
          raise "Unknown database type: #{opts[:database]}. Use :sqlite, :mysql, or :postgres."
        end
      end

      # Auto-detects database configuration from Rails and connects via Sequel.
      #
      # Extracts the connection URL from ActiveRecord's db_config. Falls back
      # to in-memory SQLite if no URL is found.
      #
      # @return [Sequel::Database] the database connection
      def connect_from_rails
        db_config = ActiveRecord::Base.connection_db_config
        url = db_config.try(:url) || db_config.configuration_hash[:url]
        url ? Sequel.connect(url) : Sequel.sqlite
      end
    end
  end
end
