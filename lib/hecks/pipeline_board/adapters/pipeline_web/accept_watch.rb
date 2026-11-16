# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # Records when the server's accept loop stops running for longer than two seconds, which
      # is when a probe is refused although the process is up. The loop calls {#beat} on every
      # pass; a watcher thread {#check}s every half second. A stall is logged once, with the
      # loop's stack and the top of every other thread's, and its end when the loop beats again.
      # The watcher needs the interpreter too: when a call holds it for seconds the watcher cannot
      # log until that call returns, and then reports the stall from the time it woke late. A log
      # with no "silent" line is therefore not proof that nothing was held.
      class AcceptWatch
        # Seconds without a beat, or of late waking, that count as a stall.
        LIMIT = 2.0
        # Seconds between checks.
        EVERY = 0.5
        # Frames logged for the accept loop, and for each other thread.
        LOOP_FRAMES = 25
        OTHER_FRAMES = 4
        MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        STDERR_LOG = ->(message) { warn message }

        # @param target [#call] answers the accept loop's thread
        # @param limit [Float] seconds that make a stall
        # @param every [Float] seconds between checks
        # @param clock [#call] answers a monotonic time in seconds
        # @param log [#call] takes one message
        def initialize(target:, limit: LIMIT, every: EVERY, clock: MONOTONIC, log: STDERR_LOG)
          @target = target
          @limit = limit
          @every = every
          @clock = clock
          @log = log
          @beat = @checked = clock.call
          @stalled = false
        end

        # Notes that the accept loop is running.
        # @return [void]
        def beat = @beat = @clock.call

        # Starts the watcher thread.
        # @return [AcceptWatch] self
        def start
          @watcher = Thread.new { loop { sleep(@every) && check } }
          self
        end

        # Ends the watcher thread; safe in a signal handler, it takes no lock.
        # @return [void]
        def stop = @watcher&.kill

        # Judges the loop at one moment, logging a stall once and its end once.
        # @param now [Float] the time, from the clock
        # @return [void]
        def check(now = @clock.call)
          held = now - @checked - @every
          @checked = now
          silent = now - @beat
          stalled = silent > @limit || held > @limit
          @log.call(report(silent, held)) if stalled && !@stalled
          @log.call("board: accept loop running again") if @stalled && !stalled
          @stalled = stalled
        end

        private

        def report(silent, held)
          "board: accept loop silent for #{silent.round(1)}s, watcher woke #{[held, 0].max.round(1)}s late; threads:\n#{trace}"
        end

        def trace
          others = Thread.list.reject { |thread| thread.equal?(Thread.current) }.first(20)
          others.map { |thread| describe(thread) }.join("\n")
        end

        def describe(thread)
          accept = thread.equal?(@target.call)
          frames = thread.backtrace&.first(accept ? LOOP_FRAMES : OTHER_FRAMES) || []
          "  #{accept ? "accept loop" : "thread"} (#{thread.status.inspect}):\n    #{frames.join("\n    ")}"
        end
      end
    end
  end
end
