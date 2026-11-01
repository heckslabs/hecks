require_relative "events"
require_relative "sagas"
require_relative "../postgres/outbox"

module Hecks
  module Adapters
    class PostgresEra
      # The event, saga and outbox tables a database shares across its domains. Only the mint path
      # creates them, through `Lineage#ensure_base!`; a boot reads them and never provisions them.
      class SharedTables
        include Events
        include Sagas
        include PostgresOutbox

        # @param db [PG::Connection] the owner connection the mint path holds
        def initialize(db)
          @db = db
        end

        # Creates each shared table that is missing. Every statement is idempotent.
        #
        # @return [void]
        # @raise [PG::Error] if Postgres refuses a statement
        def provision!
          create_event_table!
          create_saga_table!
          create_outbox_table!
        end
      end
    end
  end
end
