require_relative "firing"
require_relative "firing_lock"
require_relative "schedule"

module Hecks
  module Adapters
    module Driving
      module Clock
        # The machine's own time for a running clock: `now` from the `clock` port's SystemClock,
        # and a real sleep.
        module SystemTime
          module_function

          # @return [Integer] the current time, in Unix epoch seconds
          def now
            require_relative "../../driven/system_clock"
            SystemClock.now
          end

          # @param seconds [Numeric] how long to sleep
          # @return [void]
          def sleep(seconds) = Kernel.sleep(seconds)
        end

        # Runs one clock: computes its next fire time, sleeps until then, and fires through the
        # dispatch it is given. A tick it wakes too late for is skipped and logged, never
        # replayed, and the next tick is computed from the time it woke (ADR 0184, decision 6).
        class Runner
          # How late a firing may be and still fire, in seconds.
          GRACE = 60

          # The longest single sleep, so a wall clock that jumps (a machine that slept) is seen.
          NAP = 60

          # @param clock [Bluebook::Clock] the clock to run
          # @param fire [#call] dispatches one `Firing`; answers the dispatch's outcome hash
          # @param time [#now, #sleep] the time port, `SystemTime` unless a spec gives a fake
          # @param lock [#acquired?] the single-firing lock, `FiringLock::InProcess` by default
          # @param log [#puts] where each firing, skip and refusal is written
          def initialize(clock:, fire:, time: SystemTime, lock: FiringLock::InProcess.new, log: $stderr)
            @clock = clock
            @schedule = Schedule.for(clock)
            @fire = fire
            @time = time
            @lock = lock
            @log = log
          end

          # @param ticks [Integer, nil] how many ticks to handle (fired or skipped) before
          #   returning; nil runs until the schedule has no next tick
          # @return [Integer] how many ticks fired
          def run(ticks: nil)
            fired = 0
            handled = 0
            while (due = @schedule.next_after(@time.now)) && (ticks.nil? || handled < ticks)
              fired += 1 if tick(due)
              handled += 1
            end
            note("no further tick; stopping") unless due
            fired
          end

          # Sleeps until `due`, then fires unless it woke too late or another process took it.
          #
          # @param due [Integer] the Unix seconds the tick is due
          # @return [Boolean, nil] whether it fired; nil when skipped or taken elsewhere
          def tick(due)
            wait_until(due)
            firing = Firing.new(@clock, due)
            return skip(firing) if @time.now - due > GRACE
            return note("#{firing} taken by another process") unless @lock.acquired?(@clock.name, due)

            dispatched?(firing)
          end

          private

          def wait_until(due)
            while (remaining = due - @time.now).positive?
              @time.sleep([remaining, NAP].min)
            end
          end

          def skip(firing)
            note("skipped #{firing}: woke #{@time.now - firing.due}s late; missed ticks are not replayed")
          end

          def dispatched?(firing)
            outcome = @fire.call(firing)
            ok = outcome.is_a?(Hash) && outcome[:ok] == true
            note(ok ? "fired #{firing}: #{@clock.command}" : "#{firing}: #{@clock.command} refused: #{outcome[:error]}")
            ok
          end

          # Writes one line to the log, and answers nil.
          def note(text)
            @log.puts("[clock #{@clock.name}] #{text}")
            nil
          end
        end
      end
    end
  end
end
