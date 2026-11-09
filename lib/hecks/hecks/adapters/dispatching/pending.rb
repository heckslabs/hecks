# frozen_string_literal: true

require_relative "planned_cache"

module Hecks
  module Adapters
    class Dispatching
      # What a confirmed filling leaves for the next beat of the clock to act on, for the whole
      # process: a roll that was refused because a filling was running, whether the last filling was
      # stopped by the boot budget or held back by load or a pause, and when the clock last looked.
      # Only a confirmed filling writes these flags; a dry plan and the board only read, so looking
      # at the queue never changes what the next beat does. The flags are plain values written from
      # the thread that sets them and read on the next beat, so a race costs at most one beat.
      module Pending
        @deferred = false
        @budget_stopped = false
        @load_stopped = false
        @looked_at = nil
        @budget_frees_at = nil

        class << self
          # @return [Boolean] whether the last confirmed filling was stopped by the boot budget
          attr_accessor :budget_stopped

          # @return [Boolean] whether the last confirmed filling left planned work waiting on the
          #   machine: the load was over its limit, or the machine's crossings paused it
          attr_accessor :load_stopped

          # @return [Time, nil] when the clock last looked at what had become due
          attr_accessor :looked_at

          # @return [Time, nil] when the oldest run the budget counts leaves its window, so the
          #   budget cannot free before then unless the record changes
          attr_accessor :budget_frees_at

          # Remembers that a roll was refused because a filling was running, so whatever capacity
          # the running filling frees is not lost.
          # @return [true]
          def defer! = @deferred = true

          # @return [Boolean] whether a roll was deferred since the last call; the mark is cleared
          def take_deferred!
            was = @deferred
            @deferred = false
            was
          end

          # @return [Boolean] whether a roll is waiting to be made
          def deferred? = @deferred

          # Forgets everything, for a test.
          # @return [void]
          def reset!
            @deferred = false
            @budget_stopped = false
            @load_stopped = false
            @looked_at = nil
            @budget_frees_at = nil
            PlannedCache.clear!
          end
        end
      end
    end
  end
end
