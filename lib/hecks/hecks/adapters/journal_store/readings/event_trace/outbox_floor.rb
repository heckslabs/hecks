# frozen_string_literal: true

require "time"

module Hecks
  module Adapters
    class JournalStore
      module Readings
        module EventTrace
          # The first outbox row a trace needs to look at. A trace answers for the newest events, and
          # an outbox row is queued when its event happens, so the rows for those events sit at the
          # end of the table. The floor is found by halving the table on `enqueued_at`, so a trace
          # reads the rows of its own window and never the whole outbox, however long the ledger is.
          class OutboxFloor
            # Rows are queued a little after the event; this much earlier is still looked at.
            MARGIN = 60

            # @param run [#call] runs a statement with binds and answers its rows as hashes
            def initialize(run)
              @run = run
            end

            # @param events [Array<Hash>] the traced events, with `occurred_at`
            # @return [Integer] an outbox id at or before every row queued for these events
            def before(events)
              oldest = events.filter_map { |event| time(event["occurred_at"]) }.min
              return 0 unless oldest

              search(oldest - MARGIN)
            end

            private

            def search(from)
              low = 0
              high = @run.call("SELECT COALESCE(MAX(id), 0) AS id FROM hecks_outbox", []).first["id"].to_i
              while low < high
                mid = (low + high) / 2
                row = @run.call("SELECT id, enqueued_at FROM hecks_outbox WHERE id >= ? ORDER BY id LIMIT 1", [mid]).first
                low, high = narrowed(row, from, mid, low, high)
              end
              low
            end

            # A row whose time cannot be read counts as in the window, so the floor errs low.
            def narrowed(row, from, mid, low, high)
              return [low, mid] if row.nil? || row["id"].to_i >= high
              return [low, row["id"].to_i] if (time(row["enqueued_at"]) || from) >= from

              [row["id"].to_i + 1, high]
            end

            def time(value)
              Time.parse(value.to_s)
            rescue ArgumentError
              nil
            end
          end
        end
      end
    end
  end
end
