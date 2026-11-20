# frozen_string_literal: true

require "json"

# A recorded `gh` for a pull request whose checks failed: the calls made, and the replies a spec
# stages for the pull request, its Actions runs, their failed logs and its commits' files. Nothing
# shells out.
module FailedChecksGithub
  # @return [Array<Array<String>>] every `gh` argument list asked for, in order
  def calls = @calls ||= []

  # @return [Hash{Array<String> => Array}] the reply staged for each argument list
  def replies = @replies ||= {}

  # @return [#call] the runner the adapter is built with
  def runner
    lambda do |args|
      calls << args
      replies.fetch(args) { ["", "no reply for #{args.inspect}", false] }
    end
  end

  # @param number [String] the pull request's number
  # @return [Array<String>] the one read of the pull request
  def view_call(number = "42") = ["pr", "view", number, "--json", "statusCheckRollup,commits"]

  # @return [Hash] one concluded check run of the Actions run named
  def check(name, conclusion, run)
    { "__typename" => "CheckRun", "name" => name, "status" => "COMPLETED", "conclusion" => conclusion,
      "detailsUrl" => "https://github.com/acme/app/actions/runs/#{run}/job/1" }
  end

  # @return [Hash] one commit as `gh pr view --json commits` lists it
  def commit(oid, headline) = { "oid" => oid, "messageHeadline" => headline }

  # @return [String] the text as `gh run view --log-failed` prints it: job, step and time first
  def logged(job, text) = text.lines.map { |line| "#{job}\tRun specs\t2026-11-20T10:00:00.0000000Z #{line}" }.join

  # @return [Hash] one failed job with the one step named
  def job(id, name, step)
    { "databaseId" => id, "name" => name, "conclusion" => "failure",
      "steps" => [{ "name" => step, "conclusion" => "failure" }] }
  end

  # Stages the pull request's checks and commits.
  def reply_view(rollup, commits)
    replies[view_call] = [JSON.generate("statusCheckRollup" => rollup, "commits" => commits), "", true]
  end

  # Stages one Actions run: its failed jobs beside a passed one, and each failed job's log.
  def reply_run(run, jobs, logs)
    passed = { "databaseId" => 1, "name" => "lint", "conclusion" => "success", "steps" => [] }
    replies[["run", "view", run, "--json", "jobs"]] = [JSON.generate("jobs" => jobs + [passed]), "", true]
    logs.each { |id, log| replies[["run", "view", run, "--job", id.to_s, "--log-failed"]] = [log, "", true] }
  end

  # Stages the files one commit changes.
  def reply_files(oid, *paths)
    files = paths.map { |path| { "filename" => path } }
    replies[["api", "repos/{owner}/{repo}/commits/#{oid}"]] = [JSON.generate("files" => files), "", true]
  end

  # @return [String] the failed log of a job with one failing example
  def spec_log
    logged("specs (1)", <<~LOG)
      Failures:

        1) Widget counts its parts
           Failure/Error: expect(widget.parts).to eq(3)

             expected: 3
                  got: 2

           # ./spec/widget_spec.rb:12:in `block'

      3 examples, 1 failure

      Failed examples:

      rspec ./spec/widget_spec.rb:12 # Widget counts its parts
    LOG
  end

  # Stages a pull request of two commits whose one spec job failed; the older commit holds the spec.
  def stage_spec_failure
    reply_view([check("specs (1)", "FAILURE", "900"), check("lint", "SUCCESS", "900")],
               [commit("aaaaaaaaaaaa1111", "Count the parts"), commit("bbbbbbbbbbbb2222", "Rename a doc")])
    reply_run("900", [job(7, "specs (1)", "Run specs")], 7 => spec_log)
    reply_files("bbbbbbbbbbbb2222", "notes.txt")
    reply_files("aaaaaaaaaaaa1111", "spec/widget_spec.rb")
  end

  # Stages a pull request whose one job failed in a step before the specs.
  def stage_setup_failure
    reply_view([check("specs (1)", "FAILURE", "901")], [commit("aaaaaaaaaaaa1111", "Count the parts")])
    reply_run("901", [job(8, "specs (1)", "Set up Ruby")],
              8 => logged("specs (1)", "Fetching gems\nError: the gem server timed out\n"))
  end
end
