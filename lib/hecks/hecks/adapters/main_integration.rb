# frozen_string_literal: true

require "securerandom"
require "hecks/runtime/dispatcher"
require "hecks/runtime/errors"

module Hecks
  module Adapters
    # The `Integrating` port's adapter for `Integration.Advance`: dispatches the next step of every
    # open MainIntegration run, once. A landed run is verified (the quick gate only; the full
    # check is CI on the train pull request), a verified one boarded at once, and a pushed or
    # watched one has its CI run read. A run whose first verification failed (retrying, as the
    # saga's rule set it) is verified again, marked as the retry. A run in any other stage (being
    # verified or boarded, green, red, superseded or waiting for a person) is left alone. A
    # verification that leaves its run verified is followed by its boarding in the same advance.
    #
    # Each step is a dispatch of its own through the boot whose advance asked, not a dispatch from
    # inside the saga. A boarding needs `confirm` and waits while another run is pushed or watched.
    # A line ends `boarded <answer>`, `waiting: <reason>` or `needs_human: <refusal>`.
    class MainIntegration
      # The command each stage's next step dispatches.
      NEXT = { "landed" => "Verify", "retrying" => "Verify", "verified" => "Board", "pushed" => "Observe",
               "ci_running" => "Observe", "merged" => "Observe" }.freeze

      # The stage whose verification is the run's one retry.
      RETRYING = "retrying"

      # The stage of a run whose pull request merged and whose main was pulled, awaiting CI.
      MERGED = "merged"

      # @param registry [Runtime::Registry, nil] the booted registry whose runs are advanced
      # @param aggregate [Object, nil] unused
      def initialize(registry: nil, aggregate: nil)
        @registry = registry
      end

      # Dispatches each open run's next step.
      #
      # @param held [Hash] the `Integration` record: `confirm` lets a verified run board
      # @return [Hash{Symbol => Hash}] `report:` one line per open run: what was dispatched and
      #   the stage it left the run in, or why nothing was
      def step(**held)
        confirm = plain(held[:confirm]) == true
        lines = advance_open(confirm)
        { report: { value: lines.empty? ? "no open integration run" : lines.join("\n") } }
      end

      # Reads the CI run of each pushed or watched run, once, and does nothing else: a beat of the
      # clock asks it, so a merged train pull request or a finished check is noticed with no person
      # advancing. The runs are those `NEXT` maps to `Observe`, so `NEXT` stays the one table of
      # which stage takes which step; a run that took its verdict leaves them and is not read twice.
      #
      # @param _held [Hash] the `Integration` record, unused
      # @return [Hash{Symbol => Hash}] `report:` one line per run read
      # @raise [ConsoleCapture::Failure] when no run is pushed or watched (a quiet beat)
      def tend(**_held)
        lines = attend(runs.all.select { |run| NEXT[run.state] == "Observe" }, false)
        raise ConsoleCapture::Failure, "quiet: no train pull request in flight" if lines.empty?

        { report: { value: lines.join("\n") } }
      end

      private

      def advance_open(confirm) = attend(observing_first(runs.all.select { |run| NEXT.key?(run.state) }), confirm)

      # The pushed or watched runs come before the rest, so a run waiting on an earlier push boards
      # in the advance that sees that push turn green, whatever order the saga lists the runs in.
      def observing_first(open) = open.partition { |run| NEXT[run.state] == "Observe" }.flatten

      # Each given run in turn, until the code on disk differs from the code this process loaded
      # (`CodeWatch`): the pass then ends with that said, the runs it did not reach wait, and
      # the next pass starts on the current code.
      def attend(open, confirm)
        watch = CodeWatch.shared
        lines = []
        open.each do |run|
          break if watch.moved?

          lines << advance(run, confirm)
        end
        watch.moved? ? lines << watch.report : lines
      end

      def runs = Runs.new(@registry)

      # A run its verification left verified takes its boarding step in the same advance.
      def advance(run, confirm)
        line = take(run, confirm)
        after = runs.find(run.landed) if NEXT[run.state] == "Verify"
        after&.state == "verified" ? "#{line}; #{take(after, confirm)}" : line
      end

      def take(run, confirm)
        held_back = boarding_held_back(run, confirm) if NEXT[run.state] == "Board"
        return "#{run.short} #{run.state}: waiting: #{held_back}" if held_back

        dispatch(run, NEXT[run.state], confirm)
      end

      def boarding_held_back(run, confirm)
        other, checks = TrainChecks.new.blocking(runs.in_flight(except: run.landed))
        return "#{other.short} is #{other.state}#{" (#{checks.counts})" if checks}" if other
        return "advance with --confirm to push main" unless confirm

        nil
      end

      # A step that raises, or whose reaction met a defect, is recorded on its own run, and the
      # advance goes on to the next run.
      def dispatch(run, command, confirm)
        args = arguments(run, command, confirm)
        result = Runtime::Dispatcher.new(@registry).dispatch_flat("Hecks::Integration.#{command}", args)
        answered(run, command, args[:run], result.reaction_defects.first)
      rescue *Runtime::DOMAIN_REFUSALS => e
        "#{run.short} #{run.state} -> #{command} refused: #{e.message}"
      rescue StandardError, ScriptError => e
        Fault.new(@registry).record(run, command, args&.dig(:run), "#{e.class}: #{e.message}")
      end

      def answered(run, command, key, defect)
        return Fault.new(@registry).record(run, command, key, Fault.text_of(defect)) if defect

        stage = runs.find(run.landed)&.state
        "#{run.short} #{run.state} -> #{command}: now #{stage}#{Outcome.new(@registry).of(command, stage, key)}"
      end

      def arguments(run, command, confirm)
        args = { run: SecureRandom.uuid, landed: run.landed }
        args[:checkout] = run.checkout unless run.checkout.empty?
        args[:confirm] = true if command == "Board" && confirm
        args[:retried] = true if run.state == RETRYING
        args[:pulled] = true if run.state == MERGED
        args
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end

require_relative "main_integration/code_watch"
require_relative "main_integration/runs"
require_relative "main_integration/fault"
require_relative "main_integration/outcome"
require_relative "main_integration/train_checks"
