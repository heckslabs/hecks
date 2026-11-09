# frozen_string_literal: true

require "time"
require_relative "cache"
require_relative "../../hecks/adapters/started_work"

module Hecks
  module Adapters
    # Reads the last filling of the queue: which planned Work items it would start, which it skips
    # and why, plus the load and cap it saw. A rolling fill records its report on its `Roll`, so
    # the tile reads that record through the booted registry and starts no process. The report's
    # header ends with the time the fill ran (`at <ISO 8601>`), and a report is current for a
    # while after it. Where the registry holds no report, or only a stale one or one that states no
    # time, `Dispatch.Preview` is asked of a launcher: its answer is kept for a minute when there
    # is no report at all, and for five when a stale one stands, since a quiet queue rolls rarely.
    class PipelineFill
      HEADER = /\Aload ([\d.]+) \(limit ([\d.]+), (\d+) cpus\); started (\d+) of cap (\d+);/
      # The time a report's header ends with.
      RAN_AT = /; at (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)\z/
      WOULD = /\Awould start (\S+): (.*)\z/
      LAUNCHED = /\Astarted (\S+)(?: \(then refused: (.*)\))?\z/
      YIELDED = /\Ayielded (\S+): (.*)\z/
      SKIPPED = /\A(\S+) skipped: (.*)\z/
      # Seconds a launcher's preview is kept when no report is recorded.
      PREVIEW_TTL = 60
      # Seconds it is kept when the only report recorded is stale.
      STALE_PREVIEW_TTL = 300
      # Seconds a recorded report stays current after the time it states.
      FRESH_SECONDS = 900

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `report:` stands in for the last recorded report (a callable
      #   answering its text or nil), `runner:` for the launcher (a callable taking the arguments,
      #   answering its standard output), `ttl:` and `stale_ttl:` for how long a launcher's
      #   preview is kept, `fresh_seconds:` for how long a recorded report stays current, `now:` for
      #   the time as a callable answering a `Time`, `cache_clock:` for the seconds the previews'
      #   keeping counts in
      # @param root [String, nil] the checkout the launcher runs in
      # @param registry [Runtime::Registry, nil] the booted registry the `Roll` records are read
      #   from
      def initialize(aggregate: nil, settings: {}, root: nil, registry: nil)
        @root = root || Dir.pwd
        @registry = registry
        @recorded = settings[:report] || method(:recorded_report)
        @runner = settings[:runner] || ->(*args) { PipelineBoard::Probe.run(*args, chdir: @root, seconds: 120) }
        @fresh_seconds = settings.fetch(:fresh_seconds, FRESH_SECONDS)
        @now = settings[:now] || -> { Time.now.utc }
        @cache, @stale_cache = caches(settings)
      end

      # @return [Hash] `load`, `limit`, `cap`, `started`, `would_start` (slug and title), `launched`
      #   (slug) and `skipped` (slug and reason, a yielded item included)
      # @raise [PipelineBoard::Unavailable] when no current report is recorded and the launcher
      #   cannot answer
      def preview
        text = @recorded.call.to_s
        return parse(text) if current?(text)

        parse(cache_for(text).fetch(:fill) { launcher_report })
      end

      private

      # The cache that holds a launcher's answer: the longer one where a stale report stands, since
      # a report that old says the queue is quiet.
      def cache_for(text) = text.empty? ? @cache : @stale_cache

      # Whether the report states a time and that time is within the fresh window. A report that
      # states none is stale: nothing says when it was true.
      def current?(text)
        stated = RAN_AT.match(first_line(text))
        return false unless stated

        (@now.call - Time.iso8601(stated[1])) < @fresh_seconds
      rescue ArgumentError
        false
      end

      def first_line(text) = text.partition("\n").first.strip

      # @return [Array<PipelineBoard::Cache>] the cache for a launcher's answer where no report
      #   stands, and the longer-lived one for where a stale report does
      def caches(settings)
        held = settings.slice(:cache_clock).transform_keys { :clock }
        [PipelineBoard::Cache.new(ttl: settings.fetch(:ttl, PREVIEW_TTL), **held),
         PipelineBoard::Cache.new(ttl: settings.fetch(:stale_ttl, STALE_PREVIEW_TTL), **held)]
      end

      def launcher_report
        @runner.call("exe/hecks", "Dispatch.Preview", "repo.value=#{@root}", "budget_minutes.value=30").to_s
      end

      # The report of the newest `Roll` that holds one, or nil when the registry has none.
      def recorded_report
        aggregate = roll_aggregate
        return nil unless aggregate

        newest_first(aggregate).find { |report| HEADER.match?(report.lines.first.to_s) }
      end

      def roll_aggregate
        bluebook = @registry&.bluebook("Hecks")
        bluebook&.aggregates&.find { |candidate| candidate.hecks_name == "Roll" }
      end

      # @return [Array<String>] the report of each `Roll` record, the newest first
      def newest_first(aggregate)
        rolls = @registry.repository("Hecks", aggregate).all.to_a
        rolls.reverse.map { |roll| StartedWork.value(roll, :report).to_s }
      end

      def parse(text)
        lines = text.lines.map(&:strip)
        counts = HEADER.match(lines.first.to_s) or raise PipelineBoard::Unavailable, "unreadable fill report"
        header(counts).merge(would_start: pairs(lines, WOULD, :slug, :title), launched: launched(lines),
                             skipped: pairs(lines, SKIPPED, :slug, :reason) + pairs(lines, YIELDED, :slug, :reason))
      end

      def header(counts)
        { load: counts[1].to_f, limit: counts[2].to_f, cap: counts[5].to_i, started: counts[4].to_i }
      end

      def launched(lines)
        lines.filter_map { |line| (found = LAUNCHED.match(line)) && { slug: found[1] } }
      end

      def pairs(lines, pattern, first, second)
        lines.filter_map { |line| (found = pattern.match(line)) && { first => found[1], second => found[2] } }
      end
    end
  end
end
