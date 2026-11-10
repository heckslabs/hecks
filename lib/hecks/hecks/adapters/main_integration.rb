# frozen_string_literal: true

require "securerandom"
require "hecks/runtime/dispatcher"
require "hecks/runtime/errors"

module Hecks
  module Adapters
    # The `Integrating` port's adapter for `Integration.Advance`: dispatches the next step of every
    # open MainIntegration run, once. A landed run is verified, a verified one boarded, and a pushed
    # or watched one has its CI run read. A run in any other stage (being verified or boarded,
    # green, red, superseded or waiting for a person) is left alone, so a second advance in the
    # same stage dispatches nothing.
    #
    # Each step is a dispatch of its own through the boot whose advance asked, not a dispatch from
    # inside the saga, so it starts its own reaction chain. A boarding needs the advance's
    # `confirm`, and waits while another run is being pushed or watched.
    class MainIntegration
      # The command each stage's next step dispatches.
      NEXT = { "landed" => "Verify", "verified" => "Board", "pushed" => "Observe", "ci_running" => "Observe" }.freeze

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
        lines = runs.all.select { |run| NEXT.key?(run.state) }.map { |run| advance(run, confirm) }
        { report: { value: lines.empty? ? "no open integration run" : lines.join("\n") } }
      end

      private

      def runs = Runs.new(@registry)

      def advance(run, confirm)
        held_back = boarding_held_back(run, confirm) if NEXT[run.state] == "Board"
        return "#{run.short} #{run.state}: #{held_back}" if held_back

        dispatch(run, NEXT[run.state], confirm)
      end

      def boarding_held_back(run, confirm)
        other = runs.in_flight(except: run.landed).first
        return "waits for #{other.short}, which is #{other.state}" if other
        return "would board; advance with --confirm to push main" unless confirm

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

        "#{run.short} #{run.state} -> #{command}: now #{runs.find(run.landed)&.state}"
      end

      def arguments(run, command, confirm)
        args = { run: SecureRandom.uuid, landed: run.landed }
        args[:checkout] = run.checkout unless run.checkout.empty?
        args[:confirm] = true if command == "Board" && confirm
        args
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end

require_relative "main_integration/runs"
require_relative "main_integration/fault"
