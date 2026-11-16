require "fileutils"
require "open3"
require "tmpdir"

# A throwaway repository for specs that ask whether origin/main carries a commit: `git` runs in
# it, `commit` adds a file, and `squash_train_over` makes origin/main hold a "Train: main at"
# squash of a commit.
module CarriedRepository
  def repo = @repo ||= File.join(File.realpath(Dir.mktmpdir("hecks-carried")), "main")

  def git(*)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *, chdir: repo)
    raise out unless status.success?

    out.strip
  end

  def commit(file)
    File.write(File.join(repo, file), file)
    git("add", ".")
    git("commit", "-m", file)
    git("rev-parse", "HEAD")
  end

  # @return [String] the sha of the repository's first commit
  def open_repository
    FileUtils.mkdir_p(repo)
    git("init", "-q", "-b", "main", ".")
    commit("start")
  end

  def squash_train_over(landed)
    git("checkout", "-q", "-b", "squash", "HEAD~0")
    git("commit", "--allow-empty", "-m", "Train: main at #{landed[0, 12]}")
    git("update-ref", "refs/remotes/origin/main", "HEAD")
  end

  def forget_repository = FileUtils.remove_entry(File.dirname(repo))
end
