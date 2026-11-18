# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"

# A throwaway repository for the push train's specs: `git` runs in `repo`, `commit` adds a file,
# `land` merges a branch with a merge commit, and `mark` writes the landing's gate marker.
module TrainScratchRepo
  IDENTITY = { "GIT_AUTHOR_NAME" => "A", "GIT_AUTHOR_EMAIL" => "a@x.test",
               "GIT_COMMITTER_NAME" => "A", "GIT_COMMITTER_EMAIL" => "a@x.test" }.freeze

  def repo = @repo ||= Dir.mktmpdir("hecks-train-scratch")

  def git(*args, dir: repo)
    out, err, status = Open3.capture3(IDENTITY.merge(git_env), "git", *args, chdir: dir)
    raise "git #{args}: #{err}" unless status.success?

    out.strip
  end

  def git_env = {}

  def commit(name, dir: repo)
    File.write(File.join(dir, name), name)
    git("add", name, dir: dir)
    git("commit", "-q", "-m", name, dir: dir)
  end

  def land(branch)
    git("checkout", "-q", "-b", branch)
    commit(branch)
    git("checkout", "-q", "main")
    git("merge", "-q", "--no-ff", "-m", "Merge #{branch}", branch)
  end

  def head = git("rev-parse", "HEAD")

  def mark(sha, verdict: "green")
    File.write(File.join(repo, ".git", "hecks-local-main-gate.json"), JSON.generate("sha" => sha, "verdict" => verdict))
  end
end
