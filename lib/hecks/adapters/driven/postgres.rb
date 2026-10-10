require "json"

require_relative "sql_query_builder"
require_relative "postgres/schema_builder"
require_relative "postgres/codec"
require_relative "postgres/dialect"
require_relative "postgres/events"
require_relative "postgres/journal"
require_relative "postgres/repository"
require_relative "postgres/sagas"
require_relative "../../ports/persistence/append_only"
require_relative "../../query_specification/common/null_policy"
require_relative "../../query_specification/common/order_by"
require_relative "../../query_specification/field_path"
require_relative "../../runtime/errors"
require_relative "../../runtime/event"
require_relative "postgres/outbox"
require_relative "postgres/reconnect"
require_relative "postgres/shared_connection"
require_relative "../../runtime/instance"
require_relative "../../indifferent_key"

module Hecks
  module Adapters
    # The plain Postgres store: one table per aggregate, real typed columns
    # for scalars, jsonb for nested/list attributes. See `PostgresEra` for lineage/era support.
    class Postgres
      include SqlQueryBuilder
      include SchemaBuilder
      include Codec
      include Repository
      include Journal
      include Events
      include Sagas
      include PostgresOutbox
      include PostgresReconnect
      include Dialect

      SQL_TYPES = { "Integer" => "bigint", "Float" => "double precision" }.freeze

      attr_reader :aggregate

      # Names the optional persistence capabilities `Ports::Persistence::AppendOnly` may rely on.
      #
      # @return [Array<Symbol>] `[:atomic_put, :optimistic_concurrency]`
      def persistence_capabilities = [:atomic_put, :optimistic_concurrency]

      # Opens a connection to the database a world declares, scoped to its `schema` if any.
      #
      # @param name [String] the aggregate's name, used only in error messages
      # @param settings [Hash{Symbol, String => Object}] world settings for the binding;
      #   `database` (a database name or a `postgres://` URL) is required and `schema` is
      #   optional, each read under a Symbol or a String key
      # @return [PG::Connection] a live connection with `search_path` and
      #   `client_min_messages` already set
      # @raise [Runtime::WiringError] if the settings declare no `database`, or Postgres
      #   refuses the connection or the `SET` statements
      # @raise [LoadError] if the `pg` gem is not installed
      def self.connect_for(name, settings)
        require_pg(name)
        declared = IndifferentKey.read(settings, :database)
        refuse_undeclared(name, declared)
        configure(open_connection(declared), settings)
      rescue StandardError => e
        # PG is only defined once the gem loads, so the clause cannot name it.
        raise unless defined?(PG::Error) && e.is_a?(PG::Error)

        raise Runtime::WiringError,
              "cannot bind Postgres at #{declared} for #{name}: #{e.message.strip}"
      end

      # **Lazy, on purpose** — same reasoning as PostgresEra's own connect_for: a domain that
      # never wires Postgres should never need the gem installed.
      def self.require_pg(name)
        require "pg"
      rescue LoadError
        raise LoadError, "#{name} binds Postgres, which needs the pg gem: add `gem \"pg\"` to the Gemfile"
      end

      def self.refuse_undeclared(name, declared)
        return unless declared.to_s.empty?

        raise Runtime::WiringError,
              "#{name} binds Postgres, which needs a database connection, " \
              "but its world declares no \"database\"."
      end

      def self.open_connection(declared)
        return PG.connect(declared) if declared.start_with?("postgres://", "postgresql://")

        PG.connect(dbname: declared)
      end

      # A domain with `schema` set shares this Postgres instance, so every unqualified
      # reference resolves through search_path. Messages stay quiet on purpose, same as
      # PostgresEra's own: a schema/table that already exists is the ordinary case on every
      # boot after the first, not news.
      def self.configure(connection, settings)
        schema = IndifferentKey.read(settings, :schema)
        connection.exec("SET search_path TO #{connection.quote_ident(schema)}") if schema.to_s != ""
        connection.exec("SET client_min_messages = warning")
        connection
      end
      private_class_method :require_pg, :refuse_undeclared, :open_connection, :configure

      # Joins the process's shared connection for the declared database and schema, then
      # creates the aggregate, journal, event, saga and outbox tables if absent.
      #
      # @param aggregate [Bluebook::Aggregate] the aggregate whose table this adapter owns
      # @param settings [Hash{Symbol, String => Object}] world settings for the binding:
      #   `database` (required), `schema` and `domain` (optional; `domain` defaults to the
      #   aggregate's storage name and scopes saga rows)
      # @param root [String, nil] project root directory; accepted for the shared adapter
      #   constructor shape and ignored
      # @raise [Runtime::WiringError] if the settings declare no `database` or the connection
      #   is refused
      # @raise [PG::Error] if creating a table or index fails
      def initialize(aggregate:, settings: {}, root: nil)
        @aggregate = aggregate
        @settings  = settings
        @db = PostgresSharedConnection.for(aggregate.name, settings, connector: self.class)
        # Scopes saga rows; falls back to the aggregate's storage name when
        # settings gives no domain (e.g. a directly-instantiated adapter).
        @domain = setting(settings, :domain, aggregate.storage_name).to_s
        create_tables!
      end

      # Names the aggregate's table; the journal table and outbox rows are keyed off it.
      #
      # @return [String] the aggregate's snake_case storage name, unquoted
      def table = @aggregate.storage_name

      private

      def create_tables!
        create_aggregate_table!
        create_entry_table!
        create_event_table!
        create_saga_table!
        create_outbox_table!
        create_checkpoint_table!
      end

      # A setting read under its Symbol key, then its String key, then `default`.
      def setting(settings, key, default)
        return settings[key] if settings.key?(key)
        return settings[key.to_s] if settings.key?(key.to_s)

        default
      end
    end
  end
end
