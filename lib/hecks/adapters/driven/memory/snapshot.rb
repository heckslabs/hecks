module Hecks
  module Adapters
    class Memory
      # What `Memory#transaction` holds to take a crashed write back: a copy of every table the
      # adapter keeps, put back whole.
      module Snapshot
        private

        def snapshot
          { records: @records.dup, entries: @entries.dup, events: @events.dup, outbox: @outbox.dup,
            deliveries: @outbox_deliveries.dup, claims: @dispatch_claims.dup }
        end

        def restore(held)
          @records = held[:records]
          @entries = held[:entries]
          @events = held[:events]
          @outbox = held[:outbox]
          @outbox_deliveries = held[:deliveries]
          @dispatch_claims = held[:claims]
        end
      end
    end
  end
end
