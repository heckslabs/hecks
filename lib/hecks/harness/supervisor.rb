# frozen_string_literal: true

require "json"
require "open3"

module Hecks
  module Harness
    # The Ruby side of the supervisor in rust/harness: it starts `hecks-harness serve`, writes its
    # ops and reads its tells. Every tell is queued, in order, for {Run} to record; an op that waits
    # for an answer (an open or a delivery) is also handed the first tell that answers it.
    class Supervisor
      # The supervisor refused an op, or did not answer it in time.
      class Refused < StandardError; end

      BINARY = File.expand_path("../../../rust/harness/target/debug/hecks-harness", __dir__)

      # How long an op waits for the tell that answers it.
      ANSWER_SECONDS = 10

      class << self
        # @return [Supervisor, nil] the supervisor the Harness adapters reach, while a run holds one
        attr_accessor :current
      end

      # @param launch [#call] the child for a session name, as the `open` op's `program`, `args`,
      #   `model` and `cwd` (see {Launch})
      # @param binary [String] the `hecks-harness` binary
      # @param tick_ms [Integer, nil] how often the supervisor's clock ticks; a minute when nil
      def initialize(launch:, binary: BINARY, tick_ms: nil)
        @launch = launch
        @stdin, @stdout, @process = Open3.popen2(binary, "serve", *(tick_ms ? ["--tick-ms", tick_ms.to_s] : []))
        @tells = Queue.new
        @waiters = {}
        @lock = Mutex.new
        @reader = Thread.new { read }
      end

      # Starts a session's child on its brief, then the handover its seat's last child left, if any.
      #
      # @return [Hash] the `opened` tell
      # @raise [Refused] when the supervisor refuses or does not answer
      def open(name:, brief:, handover: nil)
        op = { op: "open", session: name, brief: brief, handover: handover, **@launch.call(name) }.compact
        answered(request(op) { |tell| tell["session"] == name && %w[opened refused].include?(tell["tell"]) })
      end

      # Hands a message to its addressee, written now or when its turn ends; an urgent one
      # interrupts the turn and is written as soon as it ends.
      #
      # @param marks [Hash] `about`, the message it answers, and `urgency`, "urgent" to interrupt a
      #   running turn (nil or "normal" waits for it)
      # @return [Hash] the `delivered` or `queued` tell
      # @raise [Refused] when the supervisor refuses or does not answer
      def deliver(key:, sender:, addressee:, text:, **marks)
        op = { op: "deliver", session: addressee, message: key, from: sender, text: text, about: marks[:about],
               urgent: marks[:urgency] == "urgent" || nil }.compact
        answered(request(op) { |tell| tell["message"] == key && %w[queued delivered refused].include?(tell["tell"]) })
      end

      # Closes a session's stdin; its `stopped` tell comes once the child exits.
      #
      # @return [void]
      def stop(name:) = write(op: "stop", session: name)

      # Asks the supervisor to stop every session and exit once they have; `quit` is its last tell.
      #
      # @return [void]
      def quit = write(op: "quit")

      # @param seconds [Numeric] how long to wait
      # @return [Hash, nil] the next tell, or nil when none came in time
      def next_tell(seconds) = @tells.pop(timeout: seconds)

      # Waits for the supervisor process to exit, after {quit}.
      #
      # @return [Process::Status]
      def close
        @stdin.close unless @stdin.closed?
        @reader.join(ANSWER_SECONDS)
        @process.value
      end

      private

      def answered(tell)
        raise Refused, tell["reason"].to_s if tell["tell"] == "refused"

        tell
      end

      def request(message, &answers)
        waiter = Queue.new
        @lock.synchronize { @waiters[waiter] = answers }
        write(message)
        waiter.pop(timeout: ANSWER_SECONDS) || raise(Refused, "the supervisor did not answer #{message[:op]}")
      ensure
        @lock.synchronize { @waiters.delete(waiter) }
      end

      def write(message)
        @stdin.puts(JSON.generate(message))
        @stdin.flush
      end

      def read
        @stdout.each_line do |line|
          tell = JSON.parse(line)
          @tells << tell
          hand(tell)
        end
      end

      def hand(tell)
        @lock.synchronize do
          waiter, = @waiters.find { |_, answers| answers.call(tell) }
          @waiters.delete(waiter)&.then { waiter << tell }
        end
      end
    end
  end
end
