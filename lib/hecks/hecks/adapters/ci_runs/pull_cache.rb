# frozen_string_literal: true

module Hecks
  module Adapters
    class CiRuns
      # What one process has read of a train pull request, kept for a few seconds. A beat that
      # asks again about the same branch inside the window gets the answer it already holds,
      # so a loop of reads over one pull request costs one read, not one each.
      class PullCache
        # Seconds a read is kept.
        KEEP_SECONDS = 15

        # @param clock [#call] returns the time in seconds
        # @param keep [Numeric] how long a read is kept
        def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, keep: KEEP_SECONDS)
          @clock = clock
          @keep = keep
          @held = {}
        end

        # @return [PullCache] the cache every reader in this process shares
        def self.shared = (@shared ||= new)

        # @param branch [String] a pull request's branch
        # @yieldreturn [Object] the read, made when none is held for the branch
        # @return [Object] the held read, or the one just made
        def read(branch)
          at, value = @held[branch]
          return value if at && @clock.call - at < @keep

          value = yield
          @held[branch] = [@clock.call, value]
          value
        end

        # Forgets what is held, so the next read goes to GitHub.
        # @return [void]
        def clear = @held.clear
      end
    end
  end
end
