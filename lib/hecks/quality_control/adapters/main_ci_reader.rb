# frozen_string_literal: true

require "json"
require "open3"

module Hecks
  module Adapters
    # The GitHub port of the red-main watch: the latest finished `CI` runs on `main`, newest first,
    # each with the name of its first failing job. It reads through `gh` and writes nothing. A spec
    # stands a stub with the same `runs` in its place, so no network is reached.
    class MainCiReader
      # What the watch needs of one run.
      Run = Struct.new(:id, :conclusion, :created_at, :sha, :failed_job, keyword_init: true)

      # How many finished runs are read.
      LIMIT = 5

      # @param repo [String, nil] `owner/name`; the checkout's own when nil
      def initialize(repo: nil)
        @repo = repo
      end

      # @return [Array<Run>] finished `CI` runs on main, newest first; empty when `gh` cannot answer
      def runs
        listed = gh("run", "list", "--workflow", "CI", "--branch", "main", "--status", "completed",
                    "--limit", LIMIT.to_s, "--json", "databaseId,conclusion,createdAt,headSha")
        listed.map { |run| run_of(run) }
      end

      private

      def run_of(run)
        failed = run["conclusion"] == "failure"
        Run.new(id: run["databaseId"].to_s, conclusion: run["conclusion"], created_at: run["createdAt"],
                sha: run["headSha"].to_s, failed_job: failed ? failing_job(run["databaseId"]) : nil)
      end

      def failing_job(id)
        jobs = gh("run", "view", id.to_s, "--json", "jobs")
        jobs = jobs["jobs"] if jobs.is_a?(Hash)
        job = Array(jobs).find { |candidate| candidate["conclusion"] == "failure" }
        job ? job["name"].to_s : "unknown job"
      end

      def gh(*args)
        args += ["--repo", @repo] if @repo
        out, status = Open3.capture2("gh", *args, err: File::NULL)
        status.success? ? JSON.parse(out) : []
      rescue SystemCallError, JSON::ParserError
        []
      end
    end
  end
end
