# frozen_string_literal: true

require "json"
require_relative "cache"
require_relative "pipeline_journal/tap"
require_relative "pipeline_journal/chain"

module Hecks
  module Adapters
    # The `Journal` port's adapter: answers `Events` with the newest events the tooling recorded
    # and, for each, the policies that reacted, what became of the delivery and the command it
    # reached. The persisted stores are read by the same reader `era.event_trace` uses, opened
    # read-only; an opt-in local event log (`events.jsonl`) is tailed for the domains that persist
    # nothing. The board writes to neither.
    class PipelineJournal
      include PipelineBoard::Chain

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

      # @param event [String] a bare event name, such as `WorkFinished`
      # @param count [Integer] how many of the newest to read
      # @return [Array<Hash>] the newest events of that name in the journal stores, newest first;
      #   empty when no store can be read
      def named(event, count)
        @cache.fetch([:named, event, count]) { chained(@trace.call(count, event)).sort_by { |row| row[:at].to_s }.reverse }
      rescue PipelineBoard::Unavailable
        []
      end

      private

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

      def registry = @registry ||= Hecks.describe(File.join(owner_root, DEFAULT_DOMAIN)).registry

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
