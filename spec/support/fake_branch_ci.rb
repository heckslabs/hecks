# frozen_string_literal: true

require "json"

# Answers git and gh as GitHub would for one draft and one CI run (99) of a pushed ci/<branch>: the
# run is queued for `running` reads, then completed with `jobs`. When `base_jobs` is set, the
# branch's base (`BASE`) has an ended CI run (50) with those jobs; `logs` holds each job's failed
# log by its id. `drafts` are the open drafts a head lookup finds; `ref_gone` makes a branch delete
# answer that the branch does not exist. `remote_ci` maps each pushed ci/<branch> ref to its tip: a
# plain push over another tip is refused as git refuses a non-fast-forward, a leased push whose
# lease holds replaces it.
class FakeBranchCi
  # The commit `git merge-base` answers as the branch's base.
  BASE = "base000000"

  attr_reader :calls
  attr_accessor :jobs, :running, :base_jobs, :logs, :drafts, :ref_gone, :remote_ci

  def initialize
    @running = 0
    @calls = []
    @jobs = [{ "id" => 1, "name" => "rspec", "conclusion" => "success" }]
    @logs = {}
    @drafts = [{ "number" => 7 }]
    @remote_ci = {}
  end

  def call(argv, chdir:)
    @calls << argv
    argv.first == "git" ? git(argv) : gh(argv)
  end

  private

  def gh(argv)
    return [true, logs.fetch(argv[argv.index("--job") + 1].to_i, "")] if argv.include?("--log-failed")
    return deleted if argv.include?("DELETE")
    return [true, JSON.generate("number" => 7, "state" => "closed")] if argv.include?("PATCH")

    [true, answer(argv.last.to_s)]
  end

  def answer(path)
    return "" unless path.start_with?("repos/")
    return JSON.generate(drafts) if path.include?("pulls?")
    return JSON.generate([{ "jobs" => path.include?("/50/") ? base_jobs : jobs }]) if path.include?("/jobs")
    return base_runs if path.include?("head_sha=#{BASE}")

    @running -= 1
    JSON.generate("workflow_runs" => [{ "id" => 99, "name" => "CI", "status" => @running.negative? ? "completed" : "queued" }])
  end

  def git(argv)
    return listed(argv.last) if argv[1] == "ls-remote"
    return pushed(argv) if argv[1] == "push"

    [true, argv[1] == "merge-base" ? "#{BASE}\n" : ""]
  end

  def listed(ref) = [true, remote_ci.key?(ref) ? "#{remote_ci[ref]}\t#{ref}\n" : ""]

  def pushed(argv)
    sha, ref = argv.last.split(":", 2)
    old = remote_ci[ref]
    lease = argv.find { |arg| arg.start_with?("--force-with-lease=") }
    held = lease ? lease.end_with?(":#{old}") : old.nil? || old == sha
    return [false, "! [rejected] #{sha} -> #{ref} (non-fast-forward)"] unless held

    remote_ci[ref] = sha
    [true, ""]
  end

  def deleted = ref_gone ? [false, "gh: Reference does not exist (HTTP 422)"] : [true, ""]

  def base_runs
    runs = base_jobs ? [{ "id" => 50, "name" => "CI", "status" => "completed" }] : []
    JSON.generate("workflow_runs" => runs)
  end
end
