# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"
require "hecks/tools/shard_planner"

module Hecks
  module Adapters
    # The `TimingsSource` port's adapter: finds the seconds each file took in the newest successful
    # CI run on main. `timings_from` is a directory of timing logs already on disk, or `main`, which
    # downloads the runtime-log artifacts of that run through `gh`. It refuses when it finds no
    # timing at all, and the bluebook's fallback policy plans by file size instead.
    class TimingsSource
      # Raised when no timing could be read; it is the reason `TimingsUnavailable` carries.
      class Unavailable < StandardError; end

      # The CI workflow whose runs on main hold the artifacts.
      WORKFLOW = "ci.yml"

      # @param aggregate [Object, nil] unused
      def initialize(aggregate: nil); end

      # @param held [Hash] the `ShardPlan` record: `name` and `timings_from`
      # @return [Hash] `timings:` the merged `path:seconds` lines of every log found
      # @raise [Unavailable] when there is no run, no artifact or no readable timing
      def fetch(**held)
        name, from = held.values_at(:name, :timings_from).map { |value| value.is_a?(Hash) ? value[:value] : value }
        table = Tools::ShardPlanner.merge(logs_in(from == "main" ? download(name) : from))
        raise Unavailable, "no timings found in #{from}" if table.empty?

        { timings: { value: table.map { |file, seconds| "#{file}:#{seconds}" }.sort.join("\n") } }
      end

      private

      # @return [Array<String>] the text of every file under `directory`
      def logs_in(directory)
        raise Unavailable, "#{directory} is not a directory" unless File.directory?(directory.to_s)

        files = Dir.glob(File.join(directory, "**", "*")).select { |path| File.file?(path) }
        files.sort.map { |path| File.read(path) }
      end

      # Downloads the runtime logs of the newest successful run on main into a new directory.
      #
      # @return [String] the directory
      def download(name)
        run = newest_run
        dir = Dir.mktmpdir("shard-timings-")
        pattern = "#{name.tr("_", "-")}-runtime-group-*"
        _, err, status = Open3.capture3("gh", "run", "download", run, "--pattern", pattern, "--dir", dir)
        raise Unavailable, "could not download #{pattern} of run #{run}: #{err.strip}" unless status.success?

        dir
      end

      # @return [String] the id of the newest successful run of the CI workflow on main
      def newest_run
        out, err, status = Open3.capture3("gh", "run", "list", "--workflow", WORKFLOW, "--branch", "main",
                                          "--status", "success", "--limit", "1", "--json", "databaseId")
        raise Unavailable, "could not list CI runs: #{err.strip}" unless status.success?

        JSON.parse(out).dig(0, "databaseId")&.to_s or raise Unavailable, "no successful CI run on main"
      end
    end
  end
end
