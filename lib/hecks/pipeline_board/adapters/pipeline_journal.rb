# frozen_string_literal: true

require "json"
require_relative "boot_lock"
require_relative "cache"
require_relative "pipeline_journal/tap"
require_relative "pipeline_journal/chain"
require_relative "pipeline_turns"
require_relative "pipeline_stages/cycles"
require_relative "pipeline_stages/daily_health"

module Hecks
  module Adapters
    # The `Journal` port's adapter: answers `Events` with the newest events the tooling recorded
    # and, for each, the policies that reacted, what became of the delivery and the command it
    # reached. The persisted stores are read by `schema_revision.event_trace`, opened
    # read-only; an opt-in local event log (`events.jsonl`) is tailed for the domains that persist
    # nothing. The board writes to neither.
    class PipelineJournal
      include PipelineBoard::Chain

      PROMOTION_EVENTS = %w[PromotionRecommended PromotionSettled].freeze

      # The event a stopped run's finding is filed with.
      STOPPED = "StoppedRunReported"

      DEFAULT_DOMAIN = "lib/hecks/hecks"

      # Where the opt-in event log is written when a world turns it on.
      TAP_PATH = File.join(Dir.home, ".claude", "hecks-dev", "events.jsonl")

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `trace:` stands in for the reader (a callable taking the row
      #   count and an event name or nil, answering its report), `tap:` the event log's path,
      #   `ttl:` how long a read is kept
      # @param root [String, nil] the checkout whose domain directory is read
      def initialize(aggregate: nil, settings: {}, root: nil)
        @root = root || Dir.pwd
        @trace = settings[:trace] || method(:trace)
        @tap = PipelineBoard::Tap.new(settings.fetch(:tap) { TAP_PATH })
        @cache = PipelineBoard::Cache.new(ttl: settings.fetch(:ttl, 2))
      end

      # @param limit [Hash, Integer, nil] how many events (40 when none is named)
      # @return [Hash{Symbol => String}] `text:` the events as JSON, newest first
      # Every logged event a cycle stage opens or closes on, read from the whole event log rather
      # than its tail, so a cycle is laid from the events alone.
      #
      # @param names [Array<String>] bare event names (the `CycleStage` rows' when none are named)
      # @return [Array<Hash>] the matching events as board rows, oldest first
      def cycle_events(names = PipelineBoard::Cycles.event_names)
        @cache.fetch([:cycle, names]) { @tap.named(names) }
      end

      # Every logged event a `HealthCheck` row opens or closes on, from the whole event log.
      #
      # @param names [Array<String>] bare event names (the `HealthCheck` rows' when none are named)
      # @return [Array<Hash>] the matching events as board rows, oldest first
      def health_events(names = PipelineBoard::DailyHealth.event_names)
        @cache.fetch([:health, names]) { @tap.named(names) }
      end

      # The first time each landed sha was recorded, from the tapped `BranchLanded` rows.
      #
      # @return [Hash{String => String}] the sha (seven characters) to the time it was landed
      def landed_times
        recent(200).reverse.each_with_object({}) do |row, times|
          sha = (row[:links] || {})["landed"].to_s[0, 7]
          times[sha] ||= row[:at] if row[:name] == "BranchLanded" && !sha.empty?
        end
      rescue PipelineBoard::Unavailable
        {}
      end

      # The first time each stopped run's finding was reported, from the logged and stored
      # `StoppedRunReported` events; an event's id is the finding's key.
      #
      # @return [Hash{String => String}] the finding's key to the time it was reported
      def stopped_times
        found = @tap.named([STOPPED]) + stored_named(STOPPED)
        found.sort_by { |row| row[:at].to_s }.each_with_object({}) { |row, times| times[row[:id].to_s] ||= row[:at] }
      end

      def events(limit: nil)
        { text: JSON.generate(recent(limit.is_a?(Hash) ? limit[:value] : limit)) }
      end

      # @param limit [Integer, nil] how many events
      # @return [Array<Hash>] the events, newest first, each with its `key`, `reactions` and
      #   `source`
      # @raise [PipelineBoard::Unavailable] when no store can be read and the log holds nothing
      def recent(limit = nil)
        count = limit.to_i.positive? ? limit.to_i : 40
        found = journal(count) + @tap.rows
        raise PipelineBoard::Unavailable, "no store was readable and no event log exists" if found.empty?

        found.sort_by { |row| row[:at].to_s }.reverse.first(count)
      end

      # @return [Array<Hash>] the finished turns the event log holds, oldest first
      def turns
        PipelineBoard::Turns.finished(@tap.named([PipelineBoard::Turns::EVENT]))
      end

      # @return [Hash{Symbol => String}] `text:` one card per run, from its newest `TurnFinished`
      def run_cards(limit: nil)
        { text: JSON.generate(PipelineBoard::Turns.run_cards(turns).first(count_of(limit))) }
      end

      # @return [Hash{Symbol => String}] `text:` the stuck items across runs, from `TurnFinished`
      def stuck(limit: nil)
        { text: JSON.generate(PipelineBoard::Turns.stuck(turns).first(count_of(limit))) }
      end

      # @param run [Hash, String, nil] a run key, or none for the newest turn
      # @return [Hash{Symbol => String}] `text:` the console block of that turn
      def turn_block(run: nil)
        { text: PipelineBoard::Turns.block(turns, run.is_a?(Hash) ? run[:value] : run) }
      end

      # The promotion events, from the persisted stores and the whole event log, so a recommendation
      # raised in another process is seen here. Memory keeps none across processes.
      #
      # @return [Array<Hash>] `PromotionRecommended` and `PromotionSettled` rows, newest first
      def promotions
        logged = @tap.named(PROMOTION_EVENTS)
        stored = PROMOTION_EVENTS.flat_map { |event| stored_named(event) }
        found = (logged + stored).uniq { |row| [row[:name], row[:id], row[:at]] }
        found.sort_by { |row| row[:at].to_s }.reverse
      end

      # @param event [String] a bare event name, such as `WorkFinished`
      # @param count [Integer] how many of the newest to read
      # @return [Array<Hash>] the newest events of that name in the journal stores, newest first
      # @raise [PipelineBoard::Unavailable] when no store can be read, so the tile says unknown
      #   rather than counting nothing
      def named(event, count)
        @cache.fetch([:named, event, count]) { chained(@trace.call(count, event)).sort_by { |row| row[:at].to_s }.reverse }
      end

      private

      def count_of(limit)
        count = (limit.is_a?(Hash) ? limit[:value] : limit).to_i
        count.positive? ? count : 20
      end

      def stored_named(event)
        named(event, 200)
      rescue PipelineBoard::Unavailable
        []
      end

      def journal(count)
        @cache.fetch([:trace, count]) { chained(@trace.call(count, nil)) }
      rescue PipelineBoard::Unavailable
        []
      end

      def trace(count, event)
        require "hecks"
        require "hecks/hecks/adapters/journal_store"
        reading = Adapters::JournalStore::Readings::EventTrace
        selection = reading::Selection.new(event, nil, count, nil)
        reading::Report.new(registry, selection).to_h
      rescue StandardError => e
        raise PipelineBoard::Unavailable, "journal: #{e.message[0, 80]}"
      end

      def registry
        @registry ||= PipelineBoard::BootLock.exclusive(wait: PipelineBoard::BootLock::WAIT_SECONDS) do
          Hecks.describe(File.join(owner_root, DEFAULT_DOMAIN)).registry
        end
      end

      # The checkout whose local overlays name the stores: a linked worktree has none, so its main
      # checkout is read instead.
      def owner_root
        common = PipelineBoard::Probe.run("git", "-C", @root, "rev-parse", "--git-common-dir").strip
        File.basename(common) == ".git" ? File.dirname(File.expand_path(common, @root)) : @root
      rescue PipelineBoard::Unavailable
        @root
      end
    end
  end
end
