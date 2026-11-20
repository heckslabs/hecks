# frozen_string_literal: true

require "hecks/runtime/event_feed"
require "hecks/adapters/driven/system_clock"
require_relative "stall_watching/sightings"
require_relative "stall_watching/impediments"
require_relative "stall_watching/relieved"
require_relative "stall_watching/slot_evidence"
require_relative "machine_sampling/process_classes"

module Hecks
  module Adapters
    # The `Watching` port's adapter for `StallWatch`: reads the event tap and answers the opening
    # lines of each `StallKind` row whose closing line has not come, with how long each waited. It
    # reads the log as the `Feed` query does, through `Runtime::EventFeed`, so it boots no domain
    # and writes nothing; the clock is the machine's own.
    class StallWatching
      # The most tap lines one look reads: every rotated generation the tap keeps.
      EVERY_LINE = 10**9

      # @param registry [Runtime::Registry, nil] the booted registry; its Hecks world names the tap
      # @param aggregate [Bluebook::Aggregate, nil] `StallWatch`, whose `StallKind` rows are read
      # @param tap [String, nil] a log in place of the world's, for a spec; a boot never passes it
      # @param reads [Hash] the machine reads, each for a spec: `processes:` the `processes`
      #   evidence ({MachineSampling::ProcessClasses} when absent), `slots:` the `slots` evidence
      #   ({SlotEvidence}), `origin:` whether a commit is on origin/main ({SettledReads}, git)
      def initialize(registry: nil, aggregate: nil, tap: nil, **reads)
        @registry = registry
        @aggregate = aggregate
        @tap = tap
        @processes = reads[:processes]
        @slots = reads[:slots]
        @settled_read = SettledReads.new(origin: reads[:origin])
      end

      # @param run [Hash, String] the look that asks, as its key or the key's value
      # @return [Array<Hash>] one `Sighting` row per opening line still open within its window;
      #   none when the world declares no tap
      def unclosed(run:)
        path = tap_path
        return [] unless path

        sightings.rows(lines(path), plain(run).to_s)
      end

      # @param run [Hash, String] the look that asks, as its key or the key's value
      # @return [Array<Hash>] one `Abandoned` row per filed stall whose run has ended and which no
      #   look has closed; none when the world declares no tap
      def abandoned(run:)
        path = tap_path
        return [] unless path

        sightings.abandoned(lines(path), plain(run).to_s)
      end

      # @param run [Hash, String] the look that asks, as its key or the key's value
      # @return [Array<Hash>] one `Sighting` row per impediment, oldest first, with `filed` and
      #   `count`; none when the world declares no tap
      def impediments(run:)
        path = tap_path
        return [] unless path

        Impediments.new(sightings.open_lines(lines(path), plain(run).to_s)).rows
      end

      # @param run [Hash, String] the look that asks, as its key or the key's value
      # @return [Array<Hash>] one `Relieved` row per open call for help whose impediment the look
      #   does not hold; none when the world declares no tap
      def relieved(run:)
        path = tap_path
        return [] unless path

        read = lines(path)
        look = plain(run).to_s
        Relieved.new(read, Impediments.new(sightings.open_lines(read, look)).rows).rows(look)
      end

      private

      def sightings = Sightings.new(kinds, SystemClock.now, evidence: method(:evidence), settled_read: @settled_read)

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument

      # The evidence reads a row may name, each reading the machine and changing nothing:
      # `processes`, the busiest process class and the session that owns it; `slots`, who holds
      # each heavy-job slot and how long ago a slot last changed hands.
      def evidence(kind)
        case kind[:evidence]
        when "processes" then (@processes ||= MachineSampling::ProcessClasses.new).line
        when "slots" then (@slots ||= SlotEvidence.new).line
        end
      end

      def lines(path) = Runtime::EventFeed.new(path: path).read(since: 0, limit: EVERY_LINE)[:events]

      # The `StallKind` rows, as the bluebook declares them.
      def kinds
        rows = @aggregate&.value_objects&.find { |object| object.hecks_name == "StallKind" }
        Array(rows&.members).map { |row| row.to_h.transform_keys(&:to_sym) }
      end

      # Where the Hecks world keeps its tap, moved as a boot moves it (`HECKS_EVENT_TAP`).
      def tap_path
        return @tap if @tap

        settings = @registry&.world("Hecks")&.for_verb(Runtime::EventTap::VERB).to_h
        Runtime::EventTap.path_for(settings, Assembly.event_tap_override)
      end
    end
  end
end
