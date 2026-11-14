# frozen_string_literal: true

require_relative "backoff"
require_relative "watcher"
require_relative "dispatcher"

module Hecks
  module Adapters
    class Ticking
      # The loop the detached child runs. It waits by the {Backoff} schedule and dispatches
      # `Ticker.tick!` until a dispatch is refused or the minutes run out. After the quick period
      # it starts one {Watcher} on the pull request's checks: while that runs the chain ticks only
      # at the schedule's cap, and the watcher's exit is one tick at once, after which the
      # schedule goes on alone.
      class Chain
        # @param argv [Array<String>] run, seconds, launcher, minutes (may be absent), log
        # @param env [Hash] `HECKS_TICK_BACKOFF` (see {Backoff.parse}), `HECKS_TICK_WATCH` (branch)
        def self.run(argv, env = ENV)
          log = argv.pop
          run, seconds, launcher, minutes = argv
          backoff = Backoff.parse(env["HECKS_TICK_BACKOFF"] || seconds.to_s)
          watcher = env["HECKS_TICK_WATCH"] && Watcher.new(env["HECKS_TICK_WATCH"], clock: -> { Time.now })
          new(Dispatcher.new(run, launcher, log), backoff, minutes, watcher, RealClock.new).run(run)
        end

        # The wall clock and the real sleep; a spec stands in a clock of its own.
        class RealClock
          # @return [Time]
          def now = Time.now

          # Sleeps the seconds given.
          def nap(seconds) = sleep(seconds)
        end

        # @param dispatcher [Dispatcher]
        # @param backoff [Backoff]
        # @param minutes [String, Numeric, nil] the chain's allowance; none: only a refusal ends it
        # @param watcher [Watcher, nil]
        # @param clock [#now, #nap] the time, and a sleep of the seconds given
        def initialize(dispatcher, backoff, minutes, watcher, clock)
          @out = dispatcher
          @backoff = backoff
          @minutes = minutes
          @watcher = watcher
          @clock = clock
          @count = 0
          @slow = 0
        end

        # Runs until the chain ends.
        # @param run [String] the ticker's key, for the log's first line
        def run(run = "run")
          @out.note("chain begun for #{run} (pid #{Process.pid}, period #{@backoff.quick}s)")
          @began = @clock.now
          step until @ended
          @watcher&.stop
        end

        private

        def step
          wait(next_delay)
          return finish_outlived if outlived?

          @count += 1
          why = @out.tick(@count)
          end_with(why) if why
        end

        def next_delay
          return @backoff.quick if @backoff.quick?(elapsed)

          @watcher.start if @watcher&.state == :idle
          return @backoff.cap if @watcher&.state == :running

          @slow += 1
          @backoff.delay(elapsed, @slow - 1)
        end

        def wait(delay)
          return @clock.nap(delay) unless @watcher&.state == :running

          waited = 0
          while waited < delay
            @clock.nap(1)
            waited += 1
            return unless @watcher.poll == :running
          end
        end

        def end_with(why)
          @out.stop(why)
          @ended = true
        end

        def finish_outlived = end_with("the chain outlived its #{@minutes} minutes after #{@count} ticks")

        def elapsed = @clock.now - @began

        def outlived? = @minutes && elapsed >= @minutes.to_f * 60
      end
    end
  end
end
