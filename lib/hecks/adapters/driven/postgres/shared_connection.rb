require "monitor"

module Hecks
  module Adapters
    # One Postgres connection shared by every `Postgres` or `PostgresEra` adapter of a process
    # that targets the same database and schema, so a domain's connection count does not grow
    # with its aggregates. Each adapter class shares only with its own kind, because each opens
    # its connection its own way.
    #
    # Every call runs under one re-entrant monitor, and a transaction holds it from BEGIN to
    # COMMIT, so a second thread's statements never interleave into another thread's
    # transaction. The owning thread re-enters freely, so a nested `transaction` joins the open
    # one, whichever aggregate's adapter opened it.
    class PostgresSharedConnection
      REGISTRY = {} # rubocop:disable Style/MutableConstant
      REGISTRY_LOCK = Mutex.new
      private_constant :REGISTRY, :REGISTRY_LOCK

      # Returns the process's shared connection for a database and schema, opening it on first use.
      #
      # The key includes the pid, so a forked child opens its own instead of sharing its
      # parent's socket.
      #
      # @param name [String] the domain or aggregate name, used only in refusal messages
      # @param settings [Hash{Symbol, String => Object}] `database` and optional `schema`
      # @param connector [#connect_for] the adapter class that opens the connection
      # @return [PostgresSharedConnection] the shared handle, connected
      # @raise [Runtime::WiringError] if `database` is missing or the connection is refused
      def self.for(name, settings, connector:)
        key = [Process.pid, connector, setting(settings, :database), setting(settings, :schema)]
        REGISTRY_LOCK.synchronize do
          handle = REGISTRY[key] ||= new(name, settings, connector: connector)
          handle.reconnect! if handle.dead?
          handle
        end
      end

      # Reads one setting under its Symbol or String spelling as a string.
      #
      # @param settings [Hash{Symbol, String => Object}] the binding's settings
      # @param key [Symbol] the setting's name
      # @return [String] the value, empty when absent
      def self.setting(settings, key)
        (settings.key?(key) ? settings[key] : settings[key.to_s]).to_s
      end
      private_class_method :setting

      # Counts the shared connections this process holds open.
      #
      # @return [Integer] how many database and schema pairs have a live shared connection
      def self.open_count = REGISTRY_LOCK.synchronize { REGISTRY.values.count { |handle| !handle.dead? } }

      # Closes every shared connection and forgets it; the next `for` opens a fresh one.
      #
      # @return [void]
      def self.close_all!
        REGISTRY_LOCK.synchronize do
          REGISTRY.each_value(&:close)
          REGISTRY.clear
        end
      end

      # @param name [String] the domain or aggregate name, used only in refusal messages
      # @param settings [Hash{Symbol, String => Object}] `database` and optional `schema`
      # @param connector [#connect_for] the adapter class that opens the connection
      # @raise [Runtime::WiringError] if `database` is missing or the connection is refused
      def initialize(name, settings, connector:)
        @name = name
        @settings = settings
        @connector = connector
        @monitor = Monitor.new
        @conn = connector.connect_for(name, settings)
      end

      # Runs one parameterless statement under the connection's monitor.
      #
      # @param sql [String] the statement
      # @return [PG::Result] the statement's result
      def exec(sql, &) = @monitor.synchronize { @conn.exec(sql, &) }

      # Runs one statement with bind parameters under the connection's monitor.
      #
      # @param sql [String] the statement, with `$1`-style placeholders
      # @param binds [Array<Object>] one value per placeholder
      # @return [PG::Result] the statement's result
      def exec_params(sql, binds = [], *rest, &) = @monitor.synchronize { @conn.exec_params(sql, binds, *rest, &) }

      # Reports the server-side transaction state; blocks while another thread's transaction
      # holds the connection, so a caller never mistakes it for its own.
      #
      # @return [Integer] a `PG::PQTRANS_*` constant
      def transaction_status = @monitor.synchronize { @conn.transaction_status }

      # Runs the block in one transaction, joining one the calling thread already holds.
      #
      # @yield the writes to commit together; an exception rolls the outermost one back
      # @return [Object] the block's own value
      def transaction(&block)
        @monitor.synchronize do
          next yield if @conn.transaction_status != PG::PQTRANS_IDLE

          @conn.transaction(&block)
        end
      end

      # Reports the server process id serving the connection.
      #
      # @return [Integer] the backend pid
      def backend_pid = @monitor.synchronize { @conn.backend_pid }

      # Quotes an identifier; needs no connection round trip.
      #
      # @param name [String, Symbol] the identifier
      # @return [String] the double-quoted identifier
      def quote_ident(name) = PG::Connection.quote_ident(name.to_s)

      # Reports whether the underlying socket is closed or broken.
      #
      # @return [Boolean] true when the connection cannot run statements
      def dead? = @monitor.synchronize { @conn.finished? || @conn.status != PG::CONNECTION_OK }

      # Replaces the connection when it is dead; a no-op when another caller already did.
      #
      # @return [void]
      # @raise [Runtime::WiringError] if the new connection is refused
      def reconnect!
        @monitor.synchronize do
          next unless dead?

          @conn.close unless @conn.finished?
          @conn = @connector.connect_for(@name, @settings)
        end
      end

      # Closes the underlying connection.
      #
      # @return [void]
      def close = @monitor.synchronize { @conn.close unless @conn.finished? }
    end
  end
end
