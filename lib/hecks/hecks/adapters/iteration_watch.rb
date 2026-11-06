# frozen_string_literal: true

require "time"
require_relative "started_work"
require_relative "../../ports/clock"
require_relative "iteration_watch/setting"
require_relative "iteration_watch/log"
require_relative "iteration_watch/mine"
require_relative "iteration_watch/attempts"
require_relative "iteration_watch/waiting"
require_relative "iteration_watch/budget"

module Hecks
  module Adapters
    # Which started Work rows are bloated: stuck in another round of the same step, waiting too long,
    # or past their time budget (see `IterationWatch::Setting` for the three limits, all settings).
    #
    # It reads the Work rows, the sqlite event logs and the clock, and writes nothing. What to do
    # about a bloated row is decided by `Dispatch.Watch`, not here.
    class IterationWatch
      # One rule a row breached.
      #
      # @!attribute [r] key
      #   @return [String] the Work row's key
      # @!attribute [r] rule
      #   @return [String] `attempts`, `waiting` or `budget`
      # @!attribute [r] detail
      #   @return [String] the numbers, in words
      Breach = Struct.new(:key, :rule, :detail) do
        # @return [String] `key [rule]: detail`
        def line = "#{key} [#{rule}]: #{detail}"

        # @return [String] the reason a yielded row carries
        def reason = "bloat: #{rule}: #{detail}"
      end

      # @param registry [Runtime::Registry, nil] whose Work rows, world and clock are read
      # @param log [#events, nil] the event log; the registry's sqlite stores when nil
      # @param now [Integer, nil] epoch seconds; the registry's clock when nil
      def initialize(registry, log: nil, now: nil)
        @registry = registry
        @log = log || Log.new(registry)
        @now = now
        @limits = Setting.read(registry)
      end

      # @return [Array<Breach>] every breach of every started row, in row order
      def breaches
        events = @log.events
        StartedWork.claimed(@registry).flat_map { |row| breached(row, events) }
      end

      private

      def breached(row, events)
        mine = Mine.new(row[:key], row[:claimed_at], events).events
        found = { "attempts" => Attempts.new(@limits.attempts).call(mine), "waiting" => Waiting.new(@limits.wait_minutes).call(mine),
                  "budget" => Budget.new(@limits).call(row, now) }
        found.filter_map { |rule, detail| Breach.new(row[:key], rule, detail) if detail }
      end

      def now = @now || Ports::Clock.now(@registry)
    end
  end
end
