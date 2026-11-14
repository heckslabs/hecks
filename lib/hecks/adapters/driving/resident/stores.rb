module Hecks
  module Adapters
    module Driving
      module Resident
        # The stores a forked line opened, and their closing when its command ends. A child that
        # is slow to leave after its command (an exit handler that waits, a thread that will not
        # stop) would otherwise keep a SQLite file or a Postgres connection open, and with it any
        # lock the command left, while every other line fails as "database is locked".
        #
        # Each store is recorded as the line opens it, so the end closes exactly those: it walks
        # no heap, and it never touches a handle the child inherited from the resident. The
        # resident loads the two gems ({load}) so the child can record from its first moment.
        module Stores
          # The gems whose handles a line's stores are.
          GEMS = %w[sqlite3 pg].freeze

          # Records each SQLite database a line opens; prepended to `SQLite3::Database`.
          module Sqlite
            def initialize(...)
              super
              Stores.opened << self
            end
          end

          # Records each Postgres connection a line starts, which every way of connecting goes
          # through; prepended to the class methods of `PG::Connection`.
          module Postgres
            def connect_start(...)
              super.tap { |connection| Stores.opened << connection }
            end
          end

          module_function

          # @return [Array<Object>] the stores this process opened since {record}
          def opened = (@opened ||= [])

          # Loads the store gems in the resident, which opens nothing. A gem that is not installed
          # is left out.
          #
          # @return [void]
          def load
            GEMS.each do |name|
              require name
            rescue LoadError, StandardError
              next
            end
          end

          # Starts recording, in a forked child, the stores its line opens.
          #
          # @return [void]
          def record
            ::SQLite3::Database.prepend(Sqlite) if defined?(::SQLite3::Database)
            ::PG::Connection.singleton_class.prepend(Postgres) if defined?(::PG::Connection)
          end

          # Closes every recorded store that is still open. A transaction a store still holds is
          # rolled back, as the end of the process would have done.
          #
          # @return [void]
          def close
            opened.each { |store| close_one(store) }
            opened.clear
          end

          # Closes one store; one that refuses is left to the end of the process.
          #
          # @return [void]
          def close_one(store)
            return store.finished? || store.finish if store.respond_to?(:finish)

            store.close unless store.closed?
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
