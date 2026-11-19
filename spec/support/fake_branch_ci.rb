# frozen_string_literal: true

require "json"

# Answers git and gh as GitHub would for one draft and one CI run (99) of a pushed ci/<branch>: the
# run is queued for `running` reads, then completed with `jobs`. When `base_jobs` is set, the
# branch's base (`BASE`) has an ended CI run (50) with those jobs; `logs` holds each job's failed
# log by its id. `drafts` are the open drafts a head lookup finds; `ref_gone` makes a branch delete
# answer that the branch does not exist.
class FakeBranchCi
  # The commit `git merge-base` answers as the branch's base.
  BASE = "base000000"

  attr_reader :calls
  attr_accessor :jobs, :running, :base_jobs, :logs, :drafts, :ref_gone

  def initialize
    @running = 0
    @calls = []
    @jobs = [{ "id" => 1, "name" => "rspec", "conclusion" => "success" }]
    @logs = {}
    @drafts = [{ "number" => 7 }]
  end

  def call(argv, chdir:)
    @calls << argv
    return [true, "#{BASE}\n"] if argv[0, 2] == %w[git merge-base]
    return [true, logs.fetch(argv[argv.index("--job") + 1].to_i, "")] if argv.include?("--log-failed")
    return deleted if argv.include?("DELETE")
    return [true, JSON.generate("number" => 7, "state" => "closed")] if argv.include?("PATCH")

    [true, answer(argv.last.to_s)]
  end

  private

  def answer(path)
    return "" unless path.start_with?("repos/")
    return JSON.generate(drafts) if path.include?("pulls?")
    return JSON.generate([{ "jobs" => path.include?("/50/") ? base_jobs : jobs }]) if path.include?("/jobs")
    return base_runs if path.include?("head_sha=#{BASE}")

    @running -= 1
    JSON.generate("workflow_runs" => [{ "id" => 99, "name" => "CI", "status" => @running.negative? ? "completed" : "queued" }])
  end

  def deleted = ref_gone ? [false, "gh: Reference does not exist (HTTP 422)"] : [true, ""]

  def base_runs
    runs = base_jobs ? [{ "id" => 50, "name" => "CI", "status" => "completed" }] : []
    JSON.generate("workflow_runs" => runs)
  end
end
