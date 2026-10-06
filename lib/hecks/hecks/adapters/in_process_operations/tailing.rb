# frozen_string_literal: true

module Hecks
  module Adapters
    module InProcessOperations
      # The loop behind `stream`: drains an event log past a cursor, then waits and drains again,
      # until the block, a limit or a deadline ends it.
      module Tailing
        # Where a stream stands: log entries seen, entries handed over, whether a batch ended it.
        Tail = Struct.new(:seen, :handed, :batch_done)

        # What ends a stream and what it follows: the aggregate filter, the most entries to hand
        # over, the monotonic time to give up at, and the seconds between checks.
        Bounds = Struct.new(:aggregate, :cap, :deadline, :interval)

        private

        # The monotonic time `timeout` seconds from now, or nil when there is no timeout.
        def deadline_for(timeout) = plain(timeout) && (monotonic + plain(timeout).to_f)

        # Drains the log, then waits and drains again, until something ends the stream.
        #
        # @return [Integer] the count of log entries seen
        def watch(repository, tail, bounds, &)
          loop do
            verdict = drain(repository, tail, bounds.aggregate, bounds.cap, &)
            return tail.seen if verdict == :stop || tail.batch_done || expired?(bounds.deadline)

            sleep((bounds.interval || 0.5).to_f)
          end
        end

        # Whether the stream's deadline, when it has one, has passed.
        def expired?(deadline) = deadline && monotonic >= deadline

        # Hands over what the log holds past the tail, one entry at a time; answers `:stop` when the
        # block or the limit ends the stream, so the tail's `seen` stays just past the last entry
        # handed over.
        def drain(repository, tail, filter, cap)
          events = repository.events
          while tail.seen < events.size
            event = events[tail.seen]
            tail.seen += 1
            next unless followed?(event, filter)

            return :stop if handed_over?(tail, yield(JSON.parse(JSON.generate(event.to_h))), cap)
          end
          nil
        end

        # Records that an entry was handed over, and whether its verdict or the limit ends the
        # stream.
        def handed_over?(tail, verdict, cap)
          tail.handed += 1
          tail.batch_done ||= verdict == :batch
          verdict == :stop || (cap && tail.handed >= cap)
        end
      end
    end
  end
end
