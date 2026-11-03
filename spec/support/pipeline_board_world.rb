# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"
require "hecks/pipeline_board/adapters/pipeline_stages"

# Stand-ins for the outside the PipelineBoard readers reach: a canned `gh`, a temp git repository
# with a bare remote and a train copy, a temp jobs directory and fixed Work items.
module PipelineBoardWorld
  NOW = Time.utc(2026, 11, 2, 20, 0, 0)

  def run(sha, id, conclusion: "success", minutes: 3)
    { "databaseId" => id, "headSha" => sha * 40, "status" => "completed", "conclusion" => conclusion,
      "startedAt" => (NOW - 3600).iso8601, "updatedAt" => (NOW - 3600 + (minutes * 60)).iso8601 }
  end

  def canned_gh(runs)
    jobs = { "jobs" => [{ "name" => "rspec", "conclusion" => "failure", "startedAt" => (NOW - 600).iso8601,
                          "completedAt" => NOW.iso8601 }] }
    releases = [{ "tagName" => "v7.0.0", "isDraft" => false, "publishedAt" => (NOW - 86_400).iso8601 }]
    ->(*args) { { "run list" => runs, "run view" => jobs, "release list" => releases }.fetch(args.first(2).join(" ")) }
  end

  def git(dir, *args)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false",
                                  "-C", dir, *args)
    raise "git #{args.join(" ")}: #{out}" unless status.success?

    out
  end

  def checkout_with_remote(base)
    bare = File.join(base, "origin.git")
    Open3.capture2e("git", "init", "--bare", "-b", "main", bare)
    work = File.join(base, "work")
    Open3.capture2e("git", "clone", bare, work)
    [bare, work]
  end

  def commit(dir, name)
    File.write(File.join(dir, name), name)
    git(dir, "add", name)
    git(dir, "commit", "-m", name)
  end

  def repo_one_ahead(base)
    _bare, work = checkout_with_remote(base)
    git(work, "checkout", "-B", "main")
    commit(work, "a")
    git(work, "push", "origin", "main", "main:stable")
    commit(work, "b")
    work
  end

  def job_dir(base, id, state, detail)
    FileUtils.mkdir_p(File.join(base, id))
    File.write(File.join(base, id, "state.json"), JSON.generate("state" => state, "detail" => detail))
  end

  def work_rows
    [{ slug: "a", status: "planned", title: "A", area: [], claimed_by: "", claimed_at: "" },
     { slug: "b", status: "started", title: "B", area: [], claimed_by: "s1", claimed_at: "x" },
     { slug: "c", status: "done", title: "C", area: [], claimed_by: "", claimed_at: "" }]
  end
end
