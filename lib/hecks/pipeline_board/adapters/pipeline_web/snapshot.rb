# frozen_string_literal: true

require "time"

module Hecks
  module Adapters
    module PipelineBoard
      # The state the page shows, read in the background and held, so a request is answered at once
      # and a slow read never holds a page. Without the background thread it reads when asked.
      class Snapshot
        WAITING = { unknown: "the first read is still in progress" }.freeze

        # @param source [#call] answers the state hash
        # @param every [Numeric] seconds between reads
        # @param background [Boolean] read on a thread, not on request
        def initialize(source:, every: 10, background: true)
          @source = source
          @every = every
          @background = background
          @lock = Mutex.new
        end

        # Starts the reading thread when the snapshot is a background one.
        # @return [Snapshot] self
        def start
          @thread = Thread.new { refresh_forever } if @background
          self
        end

        # Stops the reading thread.
        def stop = @thread&.kill

        # @return [Hash] the latest state; a placeholder naming the wait before the first read ends
        def latest
          return @source.call unless @background

          @lock.synchronize { @held } || placeholder
        end

        private

        def refresh_forever
          loop do
            held = @source.call
            @lock.synchronize { @held = held }
            sleep @every
          end
        end

        def placeholder
          { generated_at: Time.now.utc.iso8601, stages: [], metrics: [], ci_runs: WAITING, slowest_jobs: WAITING,
            open_work: WAITING, sessions: WAITING, events: WAITING, fanout: WAITING }
        end
      end
    end
  end
end
