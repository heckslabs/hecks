# frozen_string_literal: true

require "hecks/rust_build/world_rows"
require "hecks/signalbox/adapters/local_response"
require "hecks/signalbox/adapters/pressure_signal"
require_relative "memory_wait"
require_relative "session_kind"

module Hecks
  module Adapters
    module Codebase
      # The wait a heavy job runs before it takes a place while the owner has `signalbox_response`
      # drive it (ADR 0222 law 3, local response): the job's own session kind ({SessionKind})
      # answers the posted band through Signalbox's Response table ({LocalResponse}), with no
      # orchestrator in the loop. Running starts it at once; deferring and waiting hold it, asking
      # again each poll until it runs, the signal goes dark or the wait gives up; leaving refuses
      # it ({Left}). While the signal is dark at the start, the memory wait runs as before.
      #
      # It boots a whole domain from a codebase adapter, which {PressureSignal} alone does not:
      # Signalbox boots in Memory once per process and only while the switch is on.
      class ResponseWait
        # Refused when the session kind's answer is to finish and leave.
        class Left < StandardError; end

        # The Tickets world verb whose `drives` switch turns local response on.
        VERB = "signalbox_response"

        # What each held answer says the session does.
        HELD = { "deferring" => "defers its heavy steps", "waiting" => "waits its turn" }.freeze

        # @param root [String] a hecks checkout whose Tickets world carries the switch
        # @return [ResponseWait, MemoryWait] the wait a heavy job runs before it takes a place:
        #   this one while the switch is on, the memory wait while it is off
        def self.before(root) = of(root) || MemoryWait.of(root)

        # @param root [String] a hecks checkout whose Tickets world carries the switch
        # @return [ResponseWait, nil] the wait while the switch is on, nil while it is off
        def self.of(root)
          return nil unless PressureSignal.drives?(RustBuild::WorldRows.row(root, VERB))

          new(fallback: MemoryWait.of(root), poll: MemoryWait.poll_of(root), give_up: MemoryWait.give_up_of(root))
        end

        # @param fallback [#wait] the wait run while the signal is dark at the start
        # @param poll [Numeric] seconds between two asks
        # @param options [Hash] `give_up:` seconds before a held job runs anyway; `base:` the
        #   environment; `pressure:` answers the current signal; `table:` answers `answer(role:,
        #   tier:, band:)`; `clock:`, `pause:` and `err:` as {MemoryWait} takes them
        def initialize(fallback:, poll:, **options)
          @fallback = fallback
          @poll = poll
          @give_up = options.fetch(:give_up, MemoryWait::GIVE_UP_AFTER)
          @base = options.fetch(:base, ENV)
          @pressure = options.fetch(:pressure) { -> { PressureSignal.current } }
          @table = options.fetch(:table) { LocalResponse.new }
          @err = options.fetch(:err, $stderr)
          @clock, @pause = timing(options)
        end

        # Waits while the session kind's answer holds the job.
        #
        # @param job [String] the job's class, for the note
        # @return [String] the note for the job's report, empty when it started at once
        # @raise [Left] when the session kind's answer is to finish and leave
        def wait(job)
          signal = @pressure.call
          return @fallback.wait(job) unless signal

          @kind = SessionKind.of(@base, job)
          answer = ask(signal, job)
          HELD.key?(answer) ? held(job, signal, answer) : ""
        end

        private

        def timing(options)
          [options.fetch(:clock) { -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) } },
           options.fetch(:pause) { ->(seconds) { sleep(seconds) } }]
        end

        def ask(signal, job)
          answer = @table.answer(**@kind, band: signal[:band].to_s)
          raise Left, "#{said(signal)}: a helper finishes and leaves; #{job} not started" if answer == "leaving"

          answer
        end

        def held(job, signal, answer)
          started = @clock.call
          @holds = "a #{@kind[:role]} #{HELD[answer]}"
          @err.puts("hecks: #{job} waiting: #{said(signal)}: #{@holds}")
          signal, answer = again(job, signal) while HELD.key?(answer) && !over?(started)
          note(job, started, signal, answer)
        end

        # One poll: a dark signal ends the wait, as no current reading holds a job.
        def again(job, signal)
          @pause.call(@poll)
          current = @pressure.call
          current ? [current, ask(current, job)] : [signal, "dark"]
        end

        def over?(started) = @clock.call - started >= @give_up

        def note(job, started, signal, answer)
          return "waited #{(@clock.call - started).round} s: #{said(signal)}: #{@holds}" unless HELD.key?(answer)

          gave_up = "pressure held #{job} for #{@give_up.round} s (#{said(signal)}); #{job} runs anyway"
          @err.puts("hecks: #{gave_up}")
          gave_up
        end

        def said(signal) = PressureSignal.said(signal)
      end
    end
  end
end
