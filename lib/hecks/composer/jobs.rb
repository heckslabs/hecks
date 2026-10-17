require "time"

module Hecks
  module Composer
    # Runs one long-running command at a time in the background, on the hecksagon side like the
    # other composer files. Fuzzing and conformance runs take seconds to minutes, so the caller
    # starts a job and the page polls {#state}.
    #
    # A job is a call to the injected runner on a worker thread. A watchdog thread ends it when
    # it outlives the timeout. Cancelling or timing out kills the worker thread only: a child
    # process the command spawned is not killed and keeps running until it exits on its own.
    # All state sits behind one mutex, so {#state} is safe to call from any thread.
    class Jobs
      # Raised by {#start} while another job is still running.
      class Busy < StandardError; end

      # How much of a job's output {#state} keeps, counted from the end.
      OUTPUT_LIMIT = 20_000

      # @param runner [#call] takes `kind:, verb:, args:, confirm:` and returns
      #   `{ok:, status:, output:}`
      # @param timeout [Numeric] seconds a job may run before it is marked "timed_out"
      def initialize(runner:, timeout: 600)
        @runner = runner
        @timeout = timeout
        @mutex = Mutex.new
        @settled = ConditionVariable.new
        @generation = 0
        @state = blank
      end

      # @param kind [String] the kind of command the runner dispatches on
      # @param verb [String] the command's verb
      # @param args [Hash] the command's arguments
      # @param confirm [String, nil] the confirmation the runner requires, if any
      # @return [true]
      # @raise [Busy] when a job is running
      def start(kind:, verb:, args: {}, confirm: nil) # rubocop:disable Naming/PredicateMethod
        @mutex.synchronize do
          raise Busy, "a job is already running" if running?

          @state = blank.merge(status: "running", verb: verb, started_at: stamp)
          launch(@generation += 1, { kind: kind, verb: verb, args: args, confirm: confirm })
        end
        true
      end

      # @return [Hash] `status` ("idle", "running", "done", "failed", "cancelled" or
      #   "timed_out"), `verb`, `started_at` and `finished_at` (ISO 8601 or nil), `ok` (nil until
      #   the job settles) and `output` (the last {OUTPUT_LIMIT} characters)
      def state
        @mutex.synchronize { @state.dup }
      end

      # Stops the running job's worker thread. A child process it spawned is not killed.
      # @return [Boolean] true when a job was running
      def cancel
        @mutex.synchronize do
          return false unless running?

          @worker.kill
          settle("cancelled", "")
          true
        end
      end

      private

      # @api private
      def blank
        { status: "idle", verb: nil, started_at: nil, finished_at: nil, ok: nil, output: "" }
      end

      # @api private
      def running? = @state[:status] == "running"

      # @api private
      def current?(generation) = generation == @generation && running?

      # @api private
      def stamp = Time.now.utc.iso8601(3)

      # @api private
      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # Starts the worker and its watchdog; the caller holds the mutex.
      # @api private
      def launch(generation, call)
        @worker = Thread.new { work(generation, call) }
        Thread.new { watch(generation) }
      end

      # @api private
      def work(generation, call)
        result = @runner.call(**call)
        conclude(generation, result[:ok] ? "done" : "failed", result[:output])
      rescue StandardError => e
        conclude(generation, "failed", e.message)
      end

      # @api private
      def conclude(generation, status, output)
        @mutex.synchronize { settle(status, output) if current?(generation) }
      end

      # Ends the job when it outlives the timeout; wakes early when the job settles first.
      # @api private
      def watch(generation)
        deadline = now + @timeout
        @mutex.synchronize do
          @settled.wait(@mutex, deadline - now) while current?(generation) && now < deadline
          expire(generation)
        end
      end

      # @api private
      def expire(generation)
        return unless current?(generation)

        @worker.kill
        settle("timed_out", "timed out after #{@timeout} seconds")
      end

      # Records how the job ended; the caller holds the mutex.
      # @api private
      def settle(status, output)
        text = output.to_s
        text = text[-OUTPUT_LIMIT..] if text.length > OUTPUT_LIMIT
        @state = @state.merge(status: status, finished_at: stamp, ok: status == "done", output: text)
        @settled.broadcast
      end
    end
  end
end
