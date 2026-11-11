# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "hecks/tools/shard_planner"

module Hecks
  module Adapters
    # The `TimingsSource` port's adapter: finds the seconds each file took in the newest
    # successful CI run that kept them. `timings_from` is a directory of timing logs already on
    # disk, or `main`, which downloads the runtime-log artifacts of that run through `gh`. It
    # refuses when it finds no timing at all, and the bluebook's fallback policy plans by file
    # size instead.
    class TimingsSource
      # Raised when no timing could be read; it is the reason `TimingsUnavailable` carries.
      class Unavailable < StandardError; end

      # The CI workflow whose runs on main hold the artifacts.
      WORKFLOW = "ci.yml"

      # How many of the newest successful runs are tried for timing artifacts before giving up.
      RECENT_RUNS = 10

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

      # Downloads the runtime logs of the newest recent successful run that holds them into a new
      # directory. A push of an attested tree skips the shards, so the newest run on main usually
      # has no logs; the pull-request run that tested the tree has them.
      #
      # @return [String] the directory
      def download(name)
        pattern = "#{name.tr("_", "-")}-runtime-group-*"
        last_error = nil
        recent_runs.each do |run|
          dir = Dir.mktmpdir("shard-timings-")
          last_error = download_into(run, pattern, dir)
          return dir unless last_error

          FileUtils.remove_entry(dir)
        end
        raise Unavailable, "could not download #{pattern} of the last #{RECENT_RUNS} runs: #{last_error}"
      end

      # @return [String, nil] why the download failed, or nil when it worked
      def download_into(run, pattern, dir)
        _, err, status = Open3.capture3("gh", "run", "download", run, "--pattern", pattern, "--dir", dir)
        status.success? ? nil : "run #{run}: #{err.strip}"
      end

      # @return [Array<String>] the ids of the newest successful runs of the CI workflow, any branch
      def recent_runs
        out, err, status = Open3.capture3("gh", "run", "list", "--workflow", WORKFLOW, "--status", "success",
                                          "--limit", RECENT_RUNS.to_s, "--json", "databaseId")
        raise Unavailable, "could not list CI runs: #{err.strip}" unless status.success?

        JSON.parse(out).map { |run| run["databaseId"].to_s }.tap do |ids|
          raise Unavailable, "no successful CI run" if ids.empty?
        end
      end
    end
  end
end
