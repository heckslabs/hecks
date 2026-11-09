# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # What a filling leaves for the next beat of the clock to act on, for the whole process:
      # a roll that was refused because a filling was running, whether the last plan was stopped by
      # the boot budget, and when the clock last looked. These flags are plain booleans written
      # from the thread that sets them and read on the next beat, so a race costs at most one beat.
      module Pending
        @deferred = false
        @budget_stopped = false
        @looked_at = nil

        class << self
          # @return [Boolean] whether the last plan was stopped by the boot budget
          attr_accessor :budget_stopped

          # @return [Time, nil] when the clock last looked at what had become due
          attr_accessor :looked_at

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
            @looked_at = nil
          end
        end
      end
    end
  end
end
