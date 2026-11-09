# frozen_string_literal: true

require_relative "cache"
require_relative "../../hecks/adapters/started_work"

module Hecks
  module Adapters
    # Reads the last filling of the queue: which planned Work items it would start, which it skips
    # and why, plus the load and cap it saw. A rolling fill records its report on its `Roll`, so
    # the tile reads that record through the booted registry and starts no process. Where the
    # registry holds no report, or the newest one has stood unchanged past the fresh window,
    # `Dispatch.Preview` is asked of a launcher and that answer is kept for a minute.
    class PipelineFill
      HEADER = /\Aload ([\d.]+) \(limit ([\d.]+), (\d+) cpus\); started (\d+) of cap (\d+);/
      WOULD = /\Awould start (\S+): (.*)\z/
      LAUNCHED = /\Astarted (\S+)(?: \(then refused: (.*)\))?\z/
      YIELDED = /\Ayielded (\S+): (.*)\z/
      SKIPPED = /\A(\S+) skipped: (.*)\z/
      # Seconds a launcher's preview is kept.
      PREVIEW_TTL = 60
      # Seconds a recorded report stays current once the board has seen it. A roll records no
      # time, so age is how long the newest report has stood unchanged; a quiet queue rolls
      # rarely, and then a launcher's preview is the fresher answer.
      FRESH_SECONDS = 900

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `report:` stands in for the last recorded report (a callable
      #   answering its text or nil), `runner:` for the launcher (a callable taking the arguments,
      #   answering its standard output), `ttl:` for how long a launcher's preview is kept,
      #   `fresh_seconds:` for how long an unchanged recorded report stays current, `clock:` for
      #   the time in seconds
      # @param root [String, nil] the checkout the launcher runs in
      # @param registry [Runtime::Registry, nil] the booted registry the `Roll` records are read
      #   from
      def initialize(aggregate: nil, settings: {}, root: nil, registry: nil)
        @root = root || Dir.pwd
        @registry = registry
        @recorded = settings[:report] || method(:recorded_report)
        @runner = settings[:runner] || ->(*args) { PipelineBoard::Probe.run(*args, chdir: @root, seconds: 120) }
        @cache = PipelineBoard::Cache.new(ttl: settings.fetch(:ttl, PREVIEW_TTL))
        @fresh_seconds = settings.fetch(:fresh_seconds, FRESH_SECONDS)
        @clock = settings[:clock] || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @seen = nil
      end

      # @return [Hash] `load`, `limit`, `cap`, `started`, `would_start` (slug and title), `launched`
      #   (slug) and `skipped` (slug and reason, a yielded item included)
      # @raise [PipelineBoard::Unavailable] when no current report is recorded and the launcher
      #   cannot answer
      def preview
        text = current(@recorded.call.to_s)
        parse(text.empty? ? @cache.fetch(:fill) { launcher_report } : text)
      end

      private

      # The recorded text while it is fresh, else an empty string.
      def current(text)
        return "" if text.empty?

        now = @clock.call
        @seen = { text: text, at: now } unless @seen && @seen[:text] == text
        now - @seen[:at] < @fresh_seconds ? text : ""
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
