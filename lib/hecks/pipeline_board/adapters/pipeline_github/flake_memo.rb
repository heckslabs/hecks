# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # What the board learned from each finished attempt of a train run: the items it failed, which
      # never change once the run has concluded. An attempt is read from GitHub once and answered
      # from here after, so a read the gather deadline cuts short keeps the attempts it finished. A
      # read that fails is not kept and is asked again. It holds only the attempts it is told are
      # still wanted, so it never holds more than the runs in the flakes window. Gather threads
      # share it, so it is guarded; the read itself runs outside the guard.
      class FlakeMemo
        def initialize
          @held = {}
          @lock = Mutex.new
        end

        # @param key [Array] a run's id and an attempt number
        # @yieldreturn [Array<Hash>] the attempt's failed items, read from GitHub
        # @return [Array<Hash>] the kept items, or the block's, which are then kept
        # @raise [Unavailable] when the block raises it; nothing is kept for the attempt
        def fetch(key)
          kept = @lock.synchronize { @held[key] }
          return kept if kept

          items = yield
          @lock.synchronize { @held[key] = items }
        end

        # Forgets every attempt but the ones named.
        # @param keys [Array<Array>] the attempts still wanted
        # @return [void]
        def keep(keys)
          wanted = keys.to_h { |key| [key, true] }
          @lock.synchronize { @held.select! { |key, _| wanted.key?(key) } }
        end

        # @return [Integer] how many attempts are kept
        def size = @lock.synchronize { @held.size }
      end
    end
  end
end
