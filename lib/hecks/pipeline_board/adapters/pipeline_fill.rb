# frozen_string_literal: true

require_relative "cache"

module Hecks
  module Adapters
    # Reads `Dispatch.Preview`: which planned Work items a filling would start, and which it skips
    # and why, plus the load and cap it saw. A query, so it writes no record and starts nothing.
    class PipelineFill
      HEADER = /\Aload ([\d.]+) \(limit ([\d.]+), (\d+) cpus\); cap (\d+), (\d+) started/
      WOULD = /\Awould start (\S+): (.*)\z/
      SKIPPED = /\A(\S+) skipped: (.*)\z/

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `runner:` stands in for the launcher (a callable taking the
      #   arguments, answering its standard output), `ttl:` for how long the preview is kept
      # @param root [String, nil] the checkout the launcher runs in
      def initialize(aggregate: nil, settings: {}, root: nil)
        @root = root || Dir.pwd
        @runner = settings[:runner] || ->(*args) { PipelineBoard::Probe.run(*args, chdir: @root, seconds: 120) }
        @cache = PipelineBoard::Cache.new(ttl: settings.fetch(:ttl, 60))
      end

      # @return [Hash] `load`, `limit`, `cap`, `started`, `would_start` (slug and title) and
      #   `skipped` (slug and reason)
      # @raise [PipelineBoard::Unavailable] when the launcher cannot answer
      def preview
        @cache.fetch(:fill) { parse(report) }
      end

      private

      def report
        @runner.call("exe/hecks", "Dispatch.Preview", "repo.value=#{@root}", "budget_minutes.value=30").to_s
      end

      def parse(text)
        lines = text.lines.map(&:strip)
        counts = HEADER.match(lines.first.to_s) or raise PipelineBoard::Unavailable, "unreadable fill report"
        { load: counts[1].to_f, limit: counts[2].to_f, cap: counts[4].to_i, started: counts[5].to_i,
          would_start: pairs(lines, WOULD, :slug, :title), skipped: pairs(lines, SKIPPED, :slug, :reason) }
      end

      def pairs(lines, pattern, first, second)
        lines.filter_map { |line| (found = pattern.match(line)) && { first => found[1], second => found[2] } }
      end
    end
  end
end
