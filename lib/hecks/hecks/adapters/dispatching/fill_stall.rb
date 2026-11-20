# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # Says whether the fill has gone quiet: no work item has started for a window while planned
      # work waits and the cap has room. It remembers, in this process, which work items were
      # started at the last look and when a new one last appeared, so it reads and starts nothing.
      #
      # The answer names the dominant reason the waiting items give, the reading behind it and the
      # setting or switch that governs it, so nobody has to run five commands to find them.
      module FillStall
        # Minutes with no start, while work waits and there is room, before the fill is stalled.
        WINDOW_MINUTES = 15

        # The setting or switch that governs each kind of wait, by the start of its skip reason.
        GOVERNORS = {
          "skipped: paused by load" => "dispatch_max_load, and the machine_marks load_high mark",
          "skipped: load"           => "dispatch_max_load, and the machine_marks load_high mark",
          "skipped: memory low"     => "the machine_marks memory mark",
          "skipped: cap"            => "the work cap (work_limits)",
          "skipped: frozen"         => "frozen_shapes",
          "skipped: held"           => "the held item's own state"
        }.freeze

        @seen = nil
        @since = nil

        class << self
          # Takes one look.
          #
          # @param started [Array<String>] keys of the started work items
          # @param now [Time] the time of the look
          # @return [Float] minutes since a start was last seen, or since the first look
          def minutes_quiet(started, now)
            @since = now if @since.nil? || (@seen && (started - @seen).any?)
            @seen = started
            ((now - @since) / 60.0)
          end

          # Forgets what was seen.
          # @return [void]
          def reset! = @seen = @since = nil
        end

        module_function

        # @param skips [Array<Plan::Skip>] the work items left waiting and why
        # @return [String] the reason most waiting items share, as "held by <kind>: <n> wait"
        def dominant(skips)
          reason = skips.map(&:reason).tally.max_by { |_, count| count }&.first.to_s
          "#{reason.sub(/\Askipped: /, "")} (#{skips.count { |skip| skip.reason == reason }} of #{skips.size} waiting)"
        end

        # @param facts [Hash] `reason:`, `reading:`, `governed_by:` and `minutes:` of a stall
        # @return [String] the brief of the wake: what held, the reading, and what governs it
        def detail(facts)
          "The fill has started nothing for #{facts[:minutes]} minutes while work waits and there is room: " \
            "#{facts[:reason]}; #{facts[:reading]}. It is governed by #{facts[:governed_by]}. " \
            "Read Dispatch.preview, and say to the owner what holds it and which switch or setting frees it."
        end

        # @param skips [Array<Plan::Skip>] the work items left waiting and why
        # @return [String] the setting or switch behind the dominant reason
        def governor(skips)
          reason = skips.map(&:reason).tally.max_by { |_, count| count }&.first.to_s
          GOVERNORS.find { |lead, _| reason.start_with?(lead) }&.last || "the plan's own rules (Dispatch.preview)"
        end
      end
    end
  end
end
