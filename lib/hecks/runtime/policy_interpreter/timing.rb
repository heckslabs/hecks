module Hecks
  module Runtime
    class PolicyInterpreter
      # Times each policy delivery with a clock the interpreter is given, and keeps the timings
      # beside the reaction log, never in a reaction record, which the Rust kernel writes in the
      # same shape. A delivery that re-enters the dispatcher runs the reactions it caused inside
      # its own span, so each timing carries its whole time and its net time (`self_ms`, with the
      # reactions it started taken out). When the outermost dispatch ends, the timings of the
      # whole cascade are handed to the thread's settle listeners (`settle_timings`). Mixed into
      # {PolicyInterpreter}.
      module Timing
        # The clock a delivery is timed with, in seconds.
        MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

        # The CPU time the process has used, in seconds.
        CPU = -> { Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) }

        # The most timings kept before the oldest are dropped.
        LIMIT = 10_000

        # Asks to hear the timings of the next dispatch that ends on this thread, once: the listener
        # is dropped as it is called, so the dispatch it starts is not measured again.
        #
        # @yield [timings] the dispatch's timings, slowest net time first
        # @return [void]
        def self.on_settled(&listener) = (Thread.current[:hecks_settle_listeners] ||= []) << listener

        # @return [Array<#call>] the listeners waiting on this thread, forgotten as they are taken
        def self.take_listeners
          Array(Thread.current[:hecks_settle_listeners]).tap { Thread.current[:hecks_settle_listeners] = [] }
        end

        # @return [Boolean] whether a listener waits on this thread
        def self.settling? = !Array(Thread.current[:hecks_settle_listeners]).empty?

        # Names the slowest delivery among `timings`, by the time it spent itself.
        #
        # @param timings [Array<Hash>] timings, as {#drain_timings} answers
        # @return [Hash, nil] the entry with the greatest net time, nil when nothing was timed
        def self.slowest(timings) = timings.max_by { |timing| timing.fetch(:self_ms, timing[:ms]) }

        # Hands over the timings noted since the last drain and forgets them.
        #
        # @return [Array<Hash{Symbol => Object}>] `{ policy:, ms:, cpu_ms:, self_ms:, self_cpu_ms:,
        #   depth: }` per delivery, in the order they ended
        def drain_timings
          drained = timings.dup
          timings.clear
          drained
        end

        # Hands the timings of the reactions an ended dispatch caused to the thread's settle
        # listeners, slowest net time first. Only the outermost dispatch of a thread settles: one a
        # reaction started leaves its timings to the dispatch that caused it.
        #
        # @return [void]
        def settle_timings
          return unless spans.empty? && Timing.settling?

          found = drain_timings.sort_by { |timing| -timing[:self_ms] }
          Timing.take_listeners.each { |listener| listener.call(found) }
        end

        private

        def timings = Thread.current[:hecks_policy_timings] ||= []

        def spans = Thread.current[:hecks_policy_spans] ||= []

        # Runs the block and notes how long it took under the policy's name, whatever it answers.
        def timed(policy)
          spans.push({ at: @clock.call, cpu: cpu_clock.call, inner: 0.0, inner_cpu: 0.0 })
          yield
        ensure
          note(policy.name, spans.pop)
        end

        def cpu_clock = @cpu_clock ||= CPU

        def note(name, span)
          wall, cpu = elapsed(span)
          credit(spans.last, wall, cpu)
          timings << entry(name, wall, cpu, span)
          timings.shift while timings.size > LIMIT
        end

        # @return [Array<Float>] the milliseconds a span took on the wall clock and on the CPU
        def elapsed(span)
          [((@clock.call - span[:at]) * 1000).round(1), ((cpu_clock.call - span[:cpu]) * 1000).round(1)]
        end

        # Notes on the span that started a reaction how much of its time the reaction took.
        def credit(parent, wall, cpu)
          parent&.merge!(inner: parent[:inner] + wall, inner_cpu: parent[:inner_cpu] + cpu)
        end

        def entry(name, wall, cpu, span)
          { policy: name, ms: wall, cpu_ms: cpu, self_ms: [wall - span[:inner], 0.0].max.round(1),
            self_cpu_ms: [cpu - span[:inner_cpu], 0.0].max.round(1), depth: spans.size }
        end
      end
    end
  end
end
