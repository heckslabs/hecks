# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # The planned work items as the clock's beat last read them, kept for a short time.
      #
      # The beat asks each minute whether the clock alone has made something eligible, and the
      # answer needs only each planned item's retry time. Reading every work item to learn that
      # would cost more the longer the ledger grew, so the items are kept for {TTL} seconds and a
      # confirmed filling, which changes which items are planned, clears them. An item planned or
      # yielded meanwhile starts a roll through its own event, so the short staleness costs the
      # beat nothing it was going to find.
      module PlannedCache
        # Seconds the planned items are kept.
        TTL = 30

        @lock = Mutex.new
        @key = nil
        @items = nil
        @read_at = nil

        class << self
          # @param key [Object] whose items these are: a registry, or a stand-in
          # @param now [Time] the time to judge the age against
          # @yield reads the planned items when none are kept
          # @return [Array] the planned items, kept or just read
          def items(key, now)
            @lock.synchronize do
              return @items if kept?(key, now)

              @key = key
              @read_at = now
              @items = yield
            end
          end

          # Forgets the items, so the next beat reads them again.
          # @return [void]
          def clear!
            @lock.synchronize { @key = @items = @read_at = nil }
          end

          private

          def kept?(key, now)
            @items && @key == key && now >= @read_at && now - @read_at < TTL
          end
        end
      end
    end
  end
end
