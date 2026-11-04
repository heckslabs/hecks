# frozen_string_literal: true

require "json"
require "open3"
require "time"
require "hecks/runtime/errors"

module Hecks
  module Adapters
    # The `CiReader` port's adapter: answers `Run`'s `Reading` query with one CI run as GitHub
    # reports it, read through `gh`. A run's cache state is read off the jobs: GitHub lists a
    # composite action as one step, so the generated-rust action's regeneration cannot be seen on
    # its own. A cache hit restores in seconds and a miss regenerates the corpus, so a run where any
    # job spent the threshold on that one step is a miss.
    class CiReader
      # The step a job that materializes the generated Rust shows for its composite action.
      GENERATED_RUST_STEP = "Run ./.github/actions/generated-rust"

      # Seconds on that step beyond which the cache missed.
      MISS_THRESHOLD_SECONDS = 60

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] the checkout `gh` runs in; this repository when nil
      def initialize(aggregate: nil, settings: {}, root: nil)
        @root = root || File.expand_path("../../../..", __dir__)
      end

      # Reads remote CI's verdict on one commit of a repository's main. Every run GitHub reports
      # for the commit on main must have settled, and every job of each must have passed or been
      # skipped.
      #
      # @param commit [Hash, String] the full commit hash
      # @param repo [Hash, String] `owner/name`
      # @return [Hash] `text:` a JSON document: `color` (`green` or `red`) and `failing_jobs`, the
      #   failing job names joined by commas, empty when green
      # @raise [Runtime::GivenNotMet] when no run exists for the commit or a run has not settled
      def head(commit:, repo:)
        sha = named(commit)
        slug = named(repo)
        runs = head_runs(sha, slug)
        settled!(runs, sha)
        failing = runs.flat_map { |run| failing_jobs(run, slug) }
        { text: JSON.generate(commit: sha, color: failing.empty? ? "green" : "red", failing_jobs: failing.join(",")) }
      end

      # @param run_id [Hash, String, Integer] the GitHub run to read
      # @return [Hash] `text:` a JSON document: the run's commit, wall seconds, conclusion, cache
      #   state, longest pole and each job's seconds
      # @raise [Runtime::GivenNotMet] when `gh` cannot read the run
      def reading(run_id:)
        id = run_id.is_a?(Hash) ? run_id.values.first : run_id
        { text: JSON.generate(document(JSON.parse(view(id.to_s)))) }
      end

      private

      # Refuses a commit with no run on main, and one with a run still going.
      def settled!(runs, sha)
        raise Runtime::GivenNotMet, "no CI run for #{sha[0, 7]} on main" if runs.empty?

        still = runs.reject { |run| run["status"] == "completed" }
        raise Runtime::GivenNotMet, "CI for #{sha[0, 7]} is still running" if still.any?
      end

      def named(value) = value.is_a?(Hash) ? value.values.first.to_s : value.to_s

      def head_runs(sha, slug)
        out, err, status = Open3.capture3("gh", "run", "list", "--repo", slug, "--commit", sha,
                                          "--branch", "main", "--limit", "100",
                                          "--json", "databaseId,status,conclusion,workflowName", chdir: @root)
        raise Runtime::GivenNotMet, "gh could not list runs for #{sha[0, 7]}: #{first_line(err)}" unless status.success?

        JSON.parse(out)
      end

      # Everything up to the first line break.
      FIRST_LINE = /[^\n]*/
      private_constant :FIRST_LINE

      # The failing jobs of one run; the workflow's name stands in when no job is named failed.
      def failing_jobs(run, slug)
        return [] if run["conclusion"] == "success"

        failed = jobs_of(run, slug).reject { |job| Hecks::CheckConclusion.certifies?(job["conclusion"]) }
        failed.empty? ? [run.fetch("workflowName")] : failed.map { |job| job.fetch("name") }
      end

      def jobs_of(run, slug)
        id = run.fetch("databaseId").to_s
        out, err, status = Open3.capture3("gh", "run", "view", id, "--repo", slug, "--json", "jobs", chdir: @root)
        raise Runtime::GivenNotMet, "gh could not read run #{id}: #{first_line(err)}" unless status.success?

        JSON.parse(out).fetch("jobs")
      end

      # The first line of a command's error output, or the empty string.
      def first_line(text) = text.to_s[FIRST_LINE].to_s

      def view(id)
        out, err, status = Open3.capture3("gh", "run", "view", id, "--json",
                                          "headSha,conclusion,createdAt,updatedAt,jobs", chdir: @root)
        raise Runtime::GivenNotMet, "gh could not read run #{id}: #{err.lines.first&.strip}" unless status.success?

        out
      end

      def document(run)
        jobs = timed(run.fetch("jobs"))
        pole = jobs.max_by { |job| job[:seconds] }
        { commit: run.fetch("headSha"), conclusion: run.fetch("conclusion"),
          wall_seconds: seconds(run.fetch("createdAt"), run.fetch("updatedAt")),
          cache_state: cache_state(run.fetch("jobs")), longest_pole: pole&.fetch(:name), jobs: jobs }
      end

      def timed(jobs)
        jobs.select { |job| job["startedAt"] && job["completedAt"] }
            .map { |job| { name: job.fetch("name"), seconds: seconds(job["startedAt"], job["completedAt"]) } }
      end

      def cache_state(jobs)
        regenerated = jobs.any? do |job|
          job.fetch("steps", []).any? { |step| regenerating?(step) }
        end
        regenerated ? "miss" : "hit"
      end

      def regenerating?(step)
        step["name"] == GENERATED_RUST_STEP && step["startedAt"] && step["completedAt"] &&
          seconds(step["startedAt"], step["completedAt"]) > MISS_THRESHOLD_SECONDS
      end

      def seconds(from, to)
        (Time.parse(to) - Time.parse(from)).round
      end
    end
  end
end
