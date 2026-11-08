# frozen_string_literal: true

require "time"

module Hecks
  module Adapters
    module PipelineBoard
      # The state the page shows, read in the background and held, so a request is answered at once
      # and a slow read never holds a page. Without the background thread it reads when asked.
      # A read that raises is recorded and the next one is tried, and the held state says how old it
      # is (`stale_seconds`), so a frozen board shows as one.
      class Snapshot
        WAITING = { unknown: "the first read is still in progress" }.freeze
        STALE_AFTER = 2

        # @param source [#call] answers the state hash
        # @param every [Numeric] seconds between reads
        # @param background [Boolean] read on a thread, not on request
        # @param now [#call] answers the current time
        def initialize(source:, every: 10, background: true, now: -> { Time.now.utc })
          @source = source
          @every = every
          @background = background
          @now = now
          @lock = Mutex.new
          @wake = Queue.new
          @started_at = now.call
        end

        # Starts the reading thread when the snapshot is a background one.
        # @return [Snapshot] self
        def start
          @thread = Thread.new { refresh_forever } if @background
          self
        end

        # Reads the state again now, rather than at the next interval, so a change the board just
        # made (a reply) shows at once.
        # @return [void]
        def refresh_now
          @wake << :now if @background
        end

        # Stops the reading thread.
        def stop = @thread&.kill

        # @return [Hash] the latest state with `stale_seconds` (age of the last good read), `stale`
        #   (older than twice the read period) and `refresh_error` (the last failure, or nil)
        def latest
          return @source.call unless @background

          @lock.synchronize { with_age(@held || placeholder) }
        end

        private

        def refresh_forever
          loop do
            read_once
            @wake.pop(timeout: @every)
          end
        end

        def read_once
          held = @source.call
          @lock.synchronize { record(held) }
        rescue StandardError => e
          @lock.synchronize { @error = "#{e.class}: #{e.message.to_s.slice(0, 100)}" }
        end

        def record(held)
          @held = held
          @error = nil
          @read_at = @now.call
        end

        def with_age(state)
          age = (@now.call - (@read_at || @started_at)).round
          state.merge(stale_seconds: age, stale: age > @every * STALE_AFTER, refresh_error: @error)
        end

        def placeholder
          { generated_at: @now.call.iso8601, stages: [], metrics: [], ci_runs: WAITING, slowest_jobs: WAITING,
            open_work: WAITING, sessions: WAITING, events: WAITING, fanout: WAITING }
        end
      end
    end
  end
end
