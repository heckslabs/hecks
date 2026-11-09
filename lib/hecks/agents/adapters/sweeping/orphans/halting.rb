# frozen_string_literal: true

module Hecks
  module Adapters
    class Sweeping
      class Orphans
        # Stops processes one at a time, and says what became of each.
        #
        # A pid can be reused between the listing and the stop, so each process is looked up again
        # just before it is stopped and left alone when its command changed or it is younger than
        # when it was listed. A refused stop (a process the user may not signal) is recorded for
        # that process and the rest go on. A process is reported stopped only once it is gone.
        class Halting
          # @param table [ProcessTable] the process table, read again for each stop
          # @param killer [#call] called with a pid to stop it
          # @param pause [#call] waits a moment for stopped processes to exit
          def initialize(table:, killer:, pause: -> { sleep(0.3) })
            @table = table
            @killer = killer
            @pause = pause
          end

          # @param entries [Array<ProcessTable::Entry>] the processes to stop
          # @return [Hash{Integer => Symbol}] each pid's outcome: `:stopped`, `:still_running`,
          #   `:reused` (not the process that was listed) or `:denied`
          def call(entries)
            current = @table.entries
            outcome = entries.to_h { |entry| [entry.pid, signal(entry, current)] }
            return outcome unless outcome.value?(:signalled)

            @pause.call
            settle(outcome, @table.entries)
          end

          private

          def signal(entry, current)
            found = current.find { |candidate| candidate.pid == entry.pid }
            return :stopped unless found
            return :reused unless found.command == entry.command && found.age >= entry.age

            @killer.call(entry.pid)
            :signalled
          rescue Errno::ESRCH
            :stopped
          rescue Errno::EPERM
            :denied
          end

          def settle(outcome, after)
            outcome.to_h do |pid, state|
              next [pid, state] unless state == :signalled

              [pid, after.any? { |entry| entry.pid == pid } ? :still_running : :stopped]
            end
          end
        end
      end
    end
  end
end
