# frozen_string_literal: true

require "time"
require "digest"
require "json"

module Hecks
  module Adapters
    module PipelineBoard
      # What is pushed to one reader: each event of the feed once, oldest first, and again when the
      # reactions to it change, so a policy's delivery shows when it settles; and the board's state
      # whenever it changes, so the page renders what it is sent instead of asking again. It ends
      # when the reader goes away, because the write the caller does for each event then raises.
      class Stream
        HEARTBEAT_EVERY = 15

        # @param feed [#call] answers the newest events, newest first, or `{unknown: reason}`
        # @param state [#call, nil] answers the board's state hash (see {Snapshot#latest})
        # @param interval [Numeric] seconds between looks at the feed and the state
        def initialize(feed:, state: nil, interval: 1.0)
          @feed = feed
          @state = state
          @interval = interval
          @seen = {}
          @state_digest = nil
          @ticks = 0
        end

        # @yieldparam event [Hash] an event row, an `unknown` note, a `state` hash or a heartbeat
        def each(&emit)
          loop do
            look(&emit)
            look_state(&emit)
            beat(&emit)
            sleep @interval
          end
        end

        private

        def look(&emit)
          rows = @feed.call
          return note(rows[:unknown], &emit) if rows.is_a?(Hash)

          rows.reverse_each { |row| once(row, &emit) }
        end

        def look_state
          return unless @state

          current = @state.call
          digest = Digest::SHA1.hexdigest(JSON.generate(current.except(:generated_at)))
          return if digest == @state_digest

          @state_digest = digest
          yield({ state: current })
        end

        def once(row)
          digest = row.hash
          yield row unless @seen[row[:key]] == digest
          @seen[row[:key]] = digest
        end

        def note(reason)
          yield({ unknown: reason }) unless @seen[:unknown] == reason
          @seen[:unknown] = reason
        end

        def beat
          @ticks += 1
          yield({ heartbeat: Time.now.utc.iso8601 }) if (@ticks % HEARTBEAT_EVERY).zero?
        end
      end
    end
  end
end
