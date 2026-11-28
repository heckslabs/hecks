# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "hecks/harness/run"

module Hecks
  module Adapters
    # The `Bringing` port's adapter for `Crew`: opens every role of a checkout's crew as a session
    # of one Harness run, on the brief and tools its role file names (see {Harness::Roles}), and
    # serves them until Ctrl-C, until every session stopped, or after `turns` turns of each. Each
    # child is the developer's own `claude` in the checkout, or, with `tapes`, played from
    # `<tapes>/<role>.jsonl` with no model. With `journal`, the run's journal is written there.
    #
    # A journal replays: each recording becomes a tape, the checkout's crew is brought up on them
    # until each session has ended the turns it ended in the run, and the replay's own journal is
    # held to the run's, act by act (`hecks-harness compare`). A role file changed since the run
    # briefs its session otherwise, and that is a surprise as much as a different send.
    class CrewHarness
      # The crew was not brought up: the binary is not built, a role or tape is missing, or the
      # supervisor did not open a session.
      class NotBroughtUp < StandardError; end

      # A replay did not do what its journal says, or could not be run.
      class NotReplayed < StandardError; end

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
      #   the turns every session ends before the crew is stopped; `journal:` the directory the
      #   run's journal is written to; each a plain value or `{value:}`
      # @return [Hash] `last:` the sessions brought up, and how the crew was stopped
      # @raise [NotBroughtUp] when the binary is not built, a role cannot be read, a tape is
      #   missing, a session is refused, or the supervisor stops telling; nothing is left running
      def bring_up(**held)
        @checkout = checkout(held)
        tapes = plain(held[:tapes])
        turns = plain(held[:turns])
        crew = roles(tapes)
        run = Harness::Run.new(launch: launch(tapes), tick_ms: TICK_MS, record: plain(held[:journal]), binary: @binary)
        { last: { value: "brought up #{crew.size} sessions (#{crew.join(", ")}); #{served(run, crew, turns)}" } }
      ensure
        run&.close
      end

      # Replays a crew run's journal through the harness, with the checkout's crew, and holds the
      # replay to it.
      #
      # @param held [Hash] `journal:` the run's journal; `checkout:` as for {#bring_up}
      # @return [Hash] `last:` how many acts of how many sessions the replay did as the journal has
      #   them
      # @raise [NotReplayed] when the journal cannot be read, has no recording for a role, or the
      #   replay did otherwise; the first act each session did otherwise is named
      def replay_journal(**held)
        @checkout = checkout(held)
        journal = File.expand_path(plain(held[:journal]))
        turns = outline(journal).transform_values { |counts| counts.fetch("turns") }
        Dir.mktmpdir("crew-replay") { |scratch| replayed(journal, turns, scratch) }
      rescue NotBroughtUp => e
        raise NotReplayed, e.message
      end

      private

      def checkout(held) = File.expand_path(plain(held[:checkout]) || Dir.pwd)

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

      # Tapes the journal's recordings, plays the crew on them until each session has ended the
      # turns it ended in the journal or has stopped, and holds the replay's journal to the run's.
      def replayed(journal, turns, scratch)
        tapes = taped(journal, turns.keys, File.join(scratch, "tapes"))
        replay = File.join(scratch, "journal")
        crew = roles(nil)
        unrecorded = crew - turns.keys
        raise NotReplayed, "the journal at #{journal} has no recording for #{unrecorded.join(", ")}" unless unrecorded.empty?

        run = Harness::Run.new(launch: launch(tapes), tick_ms: TICK_MS, record: replay, binary: @binary)
        begin
          open_crew(run, crew)
          run.pump { |tells| crew.all? { |role| finished?(tells, role, turns.fetch(role)) } }
        ensure
          run.close
        end
        held(journal, replay)
      end

      def finished?(tells, role, turns)
        mine = tells.select { |tell| tell["session"] == role }
        mine.any? { |tell| tell["tell"] == "stopped" } || mine.count { |tell| tell["tell"] == "turn_ended" } >= turns
      end

      def taped(journal, sessions, dir)
        FileUtils.mkdir_p(dir)
        sessions.each do |session|
          File.write(File.join(dir, "#{session}.jsonl"), harness("tape", File.join(journal, "#{session}.jsonl")))
        end
        dir
      end

      def outline(journal)
        raise NotReplayed, "the hecks-harness binary is not built at #{@binary}" unless File.executable?(@binary)
        raise NotReplayed, "no journal at #{journal}" unless File.directory?(journal)

        JSON.parse(harness("journal", journal))
      end

      def held(journal, replay)
        out, status = Open3.capture2(@binary, "compare", journal, replay)
        raise NotReplayed, "cannot compare #{journal} with its replay" unless [0, 1].include?(status.exitstatus)

        compared = JSON.parse(out)
        raise NotReplayed, diverged(compared) unless compared.fetch("held")

        said = "replayed #{compared.fetch("matched")} acts of #{compared.fetch("sessions")} sessions, " \
               "each as the journal has it"
        { last: { value: said } }
      end

      # Each session's first surprise, in a sentence.
      def diverged(compared)
        surprises = compared.fetch("surprises").map do |surprise|
          "#{surprise.fetch("session")} at act #{surprise.fetch("at") + 1}: the journal has " \
            "#{told(surprise["journal"])}, the replay #{told(surprise["replay"])}"
        end
        "the replay did otherwise: #{surprises.join("; ")}"
      end

      def told(act) = act ? JSON.generate(act) : "nothing"

      def harness(*args)
        out, err, status = Open3.capture3(@binary, *args)
        raise NotReplayed, err.strip.empty? ? "hecks-harness #{args.first} failed" : err.strip unless status.success?

        out
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
