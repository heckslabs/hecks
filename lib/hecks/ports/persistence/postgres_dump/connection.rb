require "uri"

module Hecks
  module Ports
    module Persistence
      class PostgresDump
        # A Postgres connection URL, split so a password reaches the tools run
        # against it through their environment and never on a command line, where
        # any user of the machine can read it from the process list.
        class Connection
          # @param url [String] a `postgres://` or `postgresql://` URL
          # @raise [PostgresDump::Error] if `url` is not a Postgres URL
          def initialize(url)
            @uri = URI.parse(url)
            raise Error, "not a postgres URL" unless %w[postgres postgresql].include?(@uri.scheme)
          end

          # Names the database the URL points at.
          #
          # @return [String] the database name, empty when the URL names none
          def database
            @uri.path.to_s.delete_prefix("/")
          end

          # Points the same server and credentials at another database.
          #
          # @param name [String] the database to connect to instead
          # @return [Connection] a new connection; this one is unchanged
          def with_database(name)
            copy = @uri.dup
            copy.path = "/#{name}"
            self.class.new(copy.to_s)
          end

          # Lists the connection settings the URL carries, in `PG.connect` keyword form.
          #
          # @return [Hash{Symbol => String, Integer}] `host`, `port`, `user`, `password`,
          #   `dbname` and `sslmode`, each only when the URL gives one; the user and password
          #   are percent-decoded
          def settings
            {
              host: (@uri.host unless @uri.host.to_s.empty?), port: @uri.port,
              user: decode(@uri.user), password: decode(@uri.password),
              dbname: (database unless database.empty?), sslmode: URI.decode_www_form(@uri.query.to_s).to_h["sslmode"]
            }.compact
          end

          # Builds the libpq environment variables for a child process.
          #
          # @return [Hash{String => String}] `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`,
          #   `PGDATABASE` and `PGSSLMODE`, each only when `settings` has the matching key
          def env
            settings.to_h { |key, value| ["PG#{key.to_s.sub('dbname', 'database').upcase}", value.to_s] }
          end

          # Opens a connection with the `pg` gem.
          #
          # @return [PG::Connection] an open connection; the caller closes it
          def connect
            require "pg"
            PG.connect(**settings)
          end

          private

          def decode(value)
            value && URI.decode_www_form_component(value)
          end
        end
      end
    end
  end
end
