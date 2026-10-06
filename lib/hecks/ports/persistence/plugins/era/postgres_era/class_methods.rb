require_relative "../../../../../runtime/errors"

module Hecks
  module Adapters
    class PostgresEra
      # The class-level surface of the adapter: the boot gate's entry point, setting lookup,
      # and the connection the shared-connection pool opens on its behalf.
      module ClassMethods
        # Resolves this boot's era, minting the next one when the shape drifted and a translation
        # edge covers it. Delegates to `LineageManager.check!`.
        #
        # @param settings [Hash{Symbol, String => Object}] persistence settings; needs `database`
        # @param directory [String, nil] where `HECKS_SCAFFOLD=1` writes a translation edge
        # @return [Integer, nil] the ordinal of the era this boot minted, or nil when none
        # @raise [Runtime::WiringError] if the database is unreachable or the mint refuses
        # @raise [Bluebook::DSL::Malformed] if a held era's text parses under no grammar
        def era_check!(registry:, bluebook:, current_text:, settings:, directory: nil)
          LineageManager.check!(
            registry: registry, bluebook: bluebook, current_text: current_text,
            settings: settings, directory: directory
          )
        end

        # Reads one setting under either its Symbol or String spelling.
        #
        # Uses `key?` rather than `||` so a stored `false` is not mistaken for an absent key.
        #
        # @return [Object, nil] the stored value, or `default` when neither spelling is present
        def setting(settings, key, default: nil)
          return settings[key] if settings.key?(key)

          str_key = key.to_s
          return settings[str_key] if settings.key?(str_key)

          default
        end

        # Opens a connection to the declared database, selecting the declared `schema` if any.
        # The caller owns the connection and closes it.
        #
        # @param name [String] the domain or aggregate name, used only in refusal messages
        # @param settings [Hash{Symbol, String => Object}] `database` is a name or `postgres://` URL
        # @return [PG::Connection] an open connection
        # @raise [Runtime::WiringError] if `database` is missing or Postgres refuses a statement
        def connect_for(name, settings)
          require_pg!(name)
          declared = declared_database(name, settings)
          connection = open_connection(declared)
          prepare_session!(connection, setting(settings, :schema))
          connection
        rescue StandardError => e
          # PG is only defined once the gem loads, so the clause cannot name it.
          raise unless defined?(PG::Error) && e.is_a?(PG::Error)

          raise bind_failure(name, declared, e)
        end

        private

        # Lazy so a domain that never wires PostgresEra does not need the pg gem.
        def require_pg!(name)
          require "pg"
        rescue LoadError
          raise LoadError, "#{name} binds PostgresEra, which needs the pg gem: add `gem \"pg\"` to the Gemfile"
        end

        def declared_database(name, settings)
          declared = setting(settings, :database)
          return declared unless declared.to_s.empty?

          raise Runtime::WiringError,
                "#{name} binds PostgresEra, which needs a database connection, " \
                "but its world declares no \"database\"."
        end

        def open_connection(declared)
          return PG.connect(declared) if declared.start_with?("postgres://", "postgresql://")

          PG.connect(dbname: declared)
        end

        # A declared `schema` means the instance is shared; search_path makes every unqualified
        # name this adapter and its lineage classes build resolve inside that schema.
        def prepare_session!(connection, schema)
          if schema.to_s != ""
            # Idempotent: the schema may not exist yet on the first boot.
            connection.exec("CREATE SCHEMA IF NOT EXISTS #{connection.quote_ident(schema)}")
            connection.exec("SET search_path TO #{connection.quote_ident(schema)}")
          end

          # Provisioning re-runs CREATE ... IF NOT EXISTS on every boot; silence the notices.
          # Warnings and above still surface.
          connection.exec("SET client_min_messages = warning")
        end

        def bind_failure(name, declared, error)
          Runtime::WiringError.new(
            "cannot bind PostgresEra at #{declared} for #{name}: #{error.message.strip} " \
            "-- to run without a database, set HECKS_ENVIRONMENT=memory (a domain needs an environments/memory overlay)"
          )
        end
      end
    end
  end
end
