# frozen_string_literal: true

require "time"
require_relative "cache"
require_relative "registry_store"
require_relative "../../hecks/adapters/started_work"

module Hecks
  module Adapters
    # Reads the last filling of the queue: which planned Work items it would start, which it skips
    # and why, plus the load and cap it saw. A rolling fill records its report on its `Roll`, so
    # the tile reads that record in this process (through the live store when the board is pointed
    # at one, else the booted registry) and starts no process. The report's header ends with the
    # time the fill ran (`at <ISO 8601>`), which the preview carries as `at`; a report is shown
    # however old, since a quiet queue rolls rarely. Only where the store holds no report at all
    # is `Dispatch.Preview` asked of a launcher, and its answer is kept for a minute so a run of
    # journal lines cannot boot it again and again.
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

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `report:` stands in for the last recorded report (a callable
      #   answering its text or nil), `runner:` for the launcher (a callable taking the arguments,
      #   answering its standard output), `ttl:` for how long a launcher's preview is kept,
      #   `cache_clock:` for the seconds the keeping counts in
      # @param root [String, nil] the checkout the launcher runs in
      # @param registry [Runtime::Registry, nil] the booted registry the `Roll` records are read
      #   from when no `store:` is named
      # @param store [#records, nil] where the `Roll` records are read: the live store when the
      #   board is pointed at one, so a report recorded by another process is found
      def initialize(aggregate: nil, settings: {}, root: nil, registry: nil, store: nil)
        @root = root || Dir.pwd
        @store = store || PipelineBoard::RegistryStore.new(registry: registry)
        @recorded = settings[:report] || method(:recorded_report)
        @runner = settings[:runner] || ->(*args) { PipelineBoard::Probe.run(*args, chdir: @root, seconds: 120) }
        held = settings.slice(:cache_clock).transform_keys { :clock }
        @cache = PipelineBoard::Cache.new(ttl: settings.fetch(:ttl, PREVIEW_TTL), **held)
      end

      # @return [Hash] `load`, `limit`, `cap`, `started`, `at` (when the report states it),
      #   `would_start` (slug and title), `launched` (slug) and `skipped` (slug and reason, a
      #   yielded item included)
      # @raise [PipelineBoard::Unavailable] when no report is recorded and the launcher cannot
      #   answer
      def preview
        text = @recorded.call.to_s
        parse(text.empty? ? @cache.fetch(:fill) { launcher_report } : text)
      end

      private

      def launcher_report
        @runner.call("exe/hecks", "Dispatch.Preview", "repo.value=#{@root}", "budget_minutes.value=30").to_s
      end

      # The report of the newest `Roll` that holds one, or nil when the store has none.
      def recorded_report = newest_first.find { |report| HEADER.match?(report.lines.first.to_s) }

      # @return [Array<String>] the report of each `Roll` record, the newest first; none when the
      #   store cannot be read or declares no `Roll`
      def newest_first
        @store.records("Hecks", "Roll").reverse.map { |roll| StartedWork.value(roll, :report).to_s }
      rescue PipelineBoard::Unavailable
        []
      end

      def parse(text)
        lines = text.lines.map(&:strip)
        counts = HEADER.match(lines.first.to_s) or raise PipelineBoard::Unavailable, "unreadable fill report"
        header(counts).merge(would_start: pairs(lines, WOULD, :slug, :title), launched: launched(lines),
                             skipped: pairs(lines, SKIPPED, :slug, :reason) + pairs(lines, YIELDED, :slug, :reason))
      end

      def header(counts)
        { load: counts[1].to_f, limit: counts[2].to_f, cap: counts[5].to_i, started: counts[4].to_i,
          at: RAN_AT.match(counts.string)&.then { |stated| stated[1] } }
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
