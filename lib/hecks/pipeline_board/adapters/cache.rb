# frozen_string_literal: true

require_relative "probe"

module Hecks
  module Adapters
    module PipelineBoard
      # Keeps each outside read for a few seconds, failures included, so a page polling every ten
      # seconds cannot hammer `gh` or the disk.
      class Cache
        # @param ttl [Numeric] seconds an answer is kept
        # @param clock [#call] the time in seconds; the monotonic clock when none is given
        def initialize(ttl: 20, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
          @ttl = ttl
          @clock = clock
          @held = {}
          @lock = Mutex.new
        end

        # @param key [Object] what is read
        # @return [Object] the held answer while it is fresh, else the block's; a block that raises
        #   {Unavailable} is held as the failure and raised again until it expires
        def fetch(key, &block)
          @lock.synchronize do
            kept = @held[key]
            kept = @held[key] = [@clock.call, attempt(&block)] unless kept && fresh?(kept)
            kept.last.is_a?(Unavailable) ? raise(kept.last) : kept.last
          end
        end

        # Forgets every held answer, so the next read asks again.
        # @return [void]
        def clear = @lock.synchronize { @held.clear }

        private

        def fresh?(kept) = @clock.call - kept.first < @ttl

        def attempt
          yield
        rescue Unavailable => e
          e
        end
      end
    end
  end
end
