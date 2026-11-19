require "tmpdir"
require "open3"
require "fileutils"

# A throwaway repository whose branch `a` is landed on main, and the ways that landing's merge is
# made to fail. The including group defines `repo`, a path under a temporary directory.
module MergeRefusalRepository
  # Runs git in the repository, naming its own identity, and raises on failure.
  #
  # @return [String] git's combined output
  def git(*)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *, chdir: repo)
    raise out unless status.success?

    out
  end

  # Writes and commits one file on the branch checked out.
  #
  # @return [String] git's output
  def commit(file, text)
    File.write(File.join(repo, file), text)
    git("add", ".")
    git("commit", "-m", file)
  end

  # Makes the repository, with branch `a` writing `file`, and checks main out.
  #
  # @return [String] git's output
  def branch_off(file, text)
    FileUtils.mkdir_p(repo)
    git("init", "-b", "main")
    commit("README", "start")
    git("checkout", "-b", "a")
    commit(file, text)
    git("checkout", "main")
  end

  # Installs a pre-merge-commit hook that prints a line and refuses.
  #
  # @return [Integer] the count of files whose mode was set
  def refuse_merge_commits
    hook = File.join(repo, ".git", "hooks", "pre-merge-commit")
    File.write(hook, "#!/bin/sh\necho 'hook says no' >&2\nexit 1\n")
    File.chmod(0o755, hook)
  end

  # @return [String] the message the landing of `a` onto main is refused with
  def refusal
    Hecks::Adapters::GitLanding::Merger.new(Hecks::Adapters::Git.new, repo, branch: "a", onto: "main").land
  rescue Hecks::Adapters::ConsoleCapture::Failure => e
    e.message
  end
end
