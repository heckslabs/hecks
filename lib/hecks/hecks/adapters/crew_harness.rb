# frozen_string_literal: true

require "hecks/harness/run"

module Hecks
  module Adapters
    # The `Bringing` port's adapter for `Crew`: opens every role of a checkout's crew as a session
    # of one Harness run, each on the brief and tools its role file names (see {Harness::Roles} and
    # {Harness::Launch.crew}), and serves them until the run is stopped. Each child is the
    # developer's own `claude` in the checkout, or, with `tapes`, played from `<tapes>/<role>.jsonl`
    # with no model. The run is stopped by Ctrl-C, once every session has stopped, or, with `turns`,
    # once every session has ended that many turns.
    class CrewHarness
      # The crew was not brought up: the binary is not built, a role or tape is missing, or the
      # supervisor did not open a session.
      class NotBroughtUp < StandardError; end

      # How often the supervisor's clock ticks while the crew is served: well inside the time the
      # pump waits for a tell, so a crew waiting on its mail is never taken for a stalled one.
      TICK_MS = 10_000

      # @param registry [Runtime::Registry, nil] unused
      # @param aggregate [Bluebook::Aggregate, nil] `Crew`; unused
      # @param settings [Hash] `binary:` the `hecks-harness` binary, in place of
      #   {Harness::Supervisor::BINARY}
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @binary = settings.fetch(:binary, Harness::Supervisor::BINARY)
      end

      # Brings up the crew and serves it until it is stopped.
      #
      # @param held [Hash] `checkout:` the checkout whose `.claude/agents` holds the crew, the
      #   directory the command runs in when nil; `tapes:` the directory of replay tapes; `turns:`
      #   the turns every session ends before the crew is stopped; each a plain value or `{value:}`
      # @return [Hash] `last:` the sessions brought up, and how the crew was stopped
      # @raise [NotBroughtUp] when the binary is not built, a role cannot be read, a tape is
      #   missing, a session is refused, or the supervisor stops telling; nothing is left running
      def bring_up(**held)
        @checkout = File.expand_path(plain(held[:checkout]) || Dir.pwd)
        tapes = plain(held[:tapes])
        turns = plain(held[:turns])
        crew = roles(tapes)
        run = Harness::Run.new(launch: launch(tapes), tick_ms: TICK_MS)
        { last: { value: "brought up #{crew.size} sessions (#{crew.join(", ")}); #{served(run, crew, turns)}" } }
      ensure
        run&.close
      end

      private

      def roles(tapes)
        raise NotBroughtUp, "the hecks-harness binary is not built at #{@binary}" unless File.executable?(@binary)

        crew = Harness::Roles.crew(root: @checkout, binary: @binary)
        raise NotBroughtUp, "no role to bring up under #{File.join(@checkout, Harness::Roles::AGENTS)}" if crew.empty?

        missing = tapes ? crew.reject { |role| File.file?(File.join(tapes, "#{role}.jsonl")) } : []
        raise NotBroughtUp, "no tape in #{tapes} for #{missing.join(", ")}" unless missing.empty?

        crew
      end

      def launch(tapes)
        started = tapes ? Harness::Launch.replay(tapes, binary: @binary) : Harness::Launch.claude(cwd: @checkout)
        Harness::Launch.crew(started, root: @checkout)
      end

      # Opens every role, then serves the run until it is stopped, and says how it was.
      def served(run, crew, turns)
        stop = false
        previous = trap("INT") { stop = true }
        open_crew(run, crew)
        warn "Crew brought up: #{crew.join(", ")} (Ctrl-C to stop)"
        run.pump { |tells| stop || ended(tells, crew, "stopped", 1) || (turns && ended(tells, crew, "turn_ended", turns)) }
        how(stop, run.tells, crew, turns)
      ensure
        trap("INT", previous || "DEFAULT")
      end

      def open_crew(run, crew)
        crew.each { |role| run.open(role, Harness::Roles.brief(role, root: @checkout, binary: @binary)) }
        raise NotBroughtUp, "the supervisor did not open #{run.unopened.join(", ")}" unless run.unopened.empty?
      end

      def how(stop, tells, crew, turns)
        return "stopped by Ctrl-C" if stop
        return "every session stopped" if ended(tells, crew, "stopped", 1)

        "stopped after #{turns} #{turns == 1 ? "turn" : "turns"} of every session"
      end

      # Whether every role has had `count` tells of `kind`.
      def ended(tells, crew, kind, count)
        crew.all? { |role| tells.count { |tell| tell["tell"] == kind && tell["session"] == role } >= count }
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
