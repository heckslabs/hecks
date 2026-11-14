module Hecks
  module Ports
    module Persistence
      # The repository's reads of its adapter's event log: the whole of it, and the events past
      # a position and their count for a follower that polls a long log. Mixed into
      # `AppendOnly`, which supplies `@adapter`.
      module EventLogReading
        # Reads the events the adapter has durably recorded.
        #
        # Written as an `if` guard, not a trailing modifier, which would evaluate against
        # `@adapter` before `initialize` runs and silently skip defining the method.
        #
        # @return [Array<Runtime::Event>, nil] recorded events, oldest first; nil when the
        #   adapter keeps no event log
        def events
          @adapter.events if @adapter.respond_to?(:events)
        end

        # Reads the recorded events past the first `position`, by the adapter's own lookup when
        # it has one (a SQL adapter reads only the new rows), else cut from the whole log.
        #
        # @param position [Integer] how many events, from the oldest, the reader has already seen
        # @return [Array<Runtime::Event>] the events after those; `[]` when there are none or
        #   the adapter keeps no event log
        def events_past(position)
          return @adapter.events_past(position) if @adapter.respond_to?(:events_past)

          (events || []).drop(position)
        end

        # Counts the recorded events, by the adapter's own count when it has one.
        #
        # @return [Integer] how many events the adapter holds; 0 when it keeps no event log
        def event_count
          @adapter.respond_to?(:event_count) ? @adapter.event_count : (events || []).size
        end
      end
    end
  end
end
