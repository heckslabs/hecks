# frozen_string_literal: true

require "time"

module Hecks
  module Adapters
    module PipelineBoard
      # Turns `gh` run and job records into the rows the board shows. A settled run never changes,
      # so its failed-job count is read once.
      module PipelineRuns
        RUN_FIELDS = "databaseId,headSha,startedAt,updatedAt,createdAt,url,conclusion,status"

        private

        def rows(limit)
          runs = read("run", "list", "--branch", self.class::BRANCH, "--workflow", self.class::WORKFLOW,
                      "--limit", limit.to_s, "--json", RUN_FIELDS)
          runs.reverse.map { |run| Thread.new { row(run) } }.map(&:value)
        end

        def row(run)
          { id: run["databaseId"], sha: run["headSha"].to_s[0, 7], started: run["startedAt"],
            wall_minutes: minutes(run["startedAt"], run["updatedAt"]), status: run["status"],
            conclusion: run["conclusion"].to_s, failed_jobs: failed_jobs(run),
            pushed: run["createdAt"], url: run["url"] }
        end

        # The jobs that failed, nil when GitHub would not list the run's jobs (so the board says so
        # instead of counting zero).
        def failed_jobs(run)
          return counted(run) unless run["status"] == "completed"
          return 0 if Hecks::CheckConclusion.certifies?(run["conclusion"])

          @settled.fetch(run["databaseId"]) { counted(run) }
        rescue PipelineBoard::Unavailable
          nil
        end

        def counted(run) = jobs_of(run["databaseId"]).count { |job| failed?(job) }

        def failed?(job) = %w[failure timed_out cancelled startup_failure].include?(job["conclusion"])

        def jobs_of(id) = read("run", "view", id.to_s, "--json", "jobs")["jobs"] || []

        def slowest(limit)
          done = read("run", "list", "--branch", self.class::BRANCH, "--workflow", self.class::WORKFLOW,
                      "--status", "completed", "--limit", "1", "--json", RUN_FIELDS).first
          return [] unless done

          timed = jobs_of(done["databaseId"]).filter_map { |job| timed(job) }
          timed.sort_by { |job| -job[:minutes] }.first(limit)
        end

        def timed(job)
          return unless job["startedAt"] && job["completedAt"]

          { name: job["name"], minutes: minutes(job["startedAt"], job["completedAt"]), conclusion: job["conclusion"].to_s }
        end

        def minutes(from, upto)
          return 0.0 unless from && upto

          ((Time.parse(upto) - Time.parse(from)) / 60.0).round(1)
        end
      end
    end
  end
end
