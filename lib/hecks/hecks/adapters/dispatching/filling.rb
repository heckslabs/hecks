# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # Whether a confirmed filling is running anywhere in this process.
      #
      # A step of a filling dispatches in this process, so the reactions it owes run inside the
      # filling. One of them may ask for a roll, and the clock's beat runs on its own thread and may
      # ask for one too; a roll that began while another filling is under way would start the same
      # work items twice, so it is refused and the filling that is running rolls once more when it
      # is done. The count is the process's, not a thread's, so a beat cannot overlap a filling that
      # a command line started on another thread.
      module Filling
        @lock = Mutex.new
        @running = 0

        class << self
          # @return [Boolean] whether a confirmed filling is running in this process
          def running? = @lock.synchronize { @running.positive? }

          # Runs the block, counting it a filling when it is a confirmed one.
          #
          # @param confirmed [Boolean] whether the filling starts sessions
          # @yield the filling's work
          # @return [Object] what the block answers
          def during(confirmed)
            return yield unless confirmed

            @lock.synchronize { @running += 1 }
            begin
              yield
            ensure
              @lock.synchronize { @running -= 1 }
            end
          end
        end
      end
    end
  end
end
