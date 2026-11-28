# frozen_string_literal: true

require "hecks"
require_relative "supervisor"
require_relative "launch"
require_relative "tells"
require_relative "roles"

module Hecks
  module Harness
    # One run of agent sessions: the Harness bluebook booted on a Memory ledger that is thrown
    # away with the run, the supervisor beside it, and the pump that records each tell.
    class Run
      # The supervisor sent no tell in time.
      class Stalled < StandardError; end

      DIR = __dir__

      # How long the pump waits for one tell.
      TELL_SECONDS = 30

      # @return [Hecks::Runtime] the booted Harness
      attr_reader :runtime

      # @return [Array<Hash>] every tell the pump has read, in order
      attr_reader :tells

      # @param launch [#call] how each session's child starts (see {Launch})
      # @param dir [String] the Harness directory to boot
      # @param tick_ms [Integer, nil] how often the supervisor's clock ticks (see {Supervisor})
      def initialize(launch:, dir: DIR, tick_ms: nil)
        @runtime = Hecks.boot(dir, install_driving: false, environment: "memory")
        @supervisor = Supervisor.current = Supervisor.new(launch: launch, tick_ms: tick_ms)
        @tells = []
      end

      # Opens a session on its brief, as the Owner.
      #
      # @return [void]
      def open(name, brief) = owner("Session.Open", name: { value: name }, brief: { value: brief })

      # Opens a session for one of the crew's roles, briefed from its role file (see {Roles}).
      #
      # @return [void]
      def open_role(role) = self.open(role, Roles.brief(role))

      # Starts a run of one role under its own key, opening its session on the brief, as the Owner.
      # The run holds the session's last report and is finished only when the session ended.
      #
      # @return [void]
      def start(key, session, brief)
        owner("AgentRun.Start", run: { value: key }, session: { value: session }, brief: { value: brief })
      end

      # Starts a run of one of the crew's roles under its own key, in a session named for the role
      # and briefed from its role file (see {Roles}).
      #
      # @return [void]
      def start_role(key, role) = start(key, role, Roles.brief(role))

      # Starts a run in a standing seat whose session stopped, as the Owner: the session is reopened
      # on the brief, and its new child starts from the handover the seat's last session left.
      #
      # @return [void]
      def take_seat(key, session, brief)
        owner("AgentRun.TakeSeat", run: { value: key }, session: { value: session }, brief: { value: brief })
      end

      # Stops a running session, as the Owner.
      #
      # @return [void]
      def stop(name) = owner("Session.Stop", session: name)

      # Records tells until the block holds for every tell read so far.
      #
      # @yieldparam tells [Array<Hash>] the tells read so far
      # @return [void]
      # @raise [Stalled] when no tell comes in {TELL_SECONDS}
      def pump
        pump_one until yield(@tells)
      end

      # Stops every session, records the rest of the tells, and waits for the supervisor to exit.
      #
      # @return [Process::Status]
      def close
        @supervisor.quit
        pump { |tells| tells.last&.fetch("tell") == "quit" }
        @supervisor.close
      ensure
        Supervisor.current = nil
      end

      private

      def pump_one
        tell = @supervisor.next_tell(TELL_SECONDS) || raise(Stalled, "no tell in #{TELL_SECONDS} s")
        @tells << tell
        Tells.record(runtime, tell)
      end

      def owner(verb, args)
        Hecks::Runtime::Caller.as(role: "Owner") { runtime.dispatch_flat("Harness::#{verb}", args) }
        nil
      end
    end
  end
end
