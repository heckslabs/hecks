require "fileutils"
require "open3"
require "tmpdir"

# A throwaway repository for specs that ask whether origin/main carries a commit: `git` runs in
# it, `commit` adds a file, and `merge_train_over` makes origin/main a merge commit of a train.
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

  # Origin moved on beside `landed`, then merged the train that boarded it in a merge commit, as
  # GitHub does: `landed` keeps its sha as the merge's second parent.
  def merge_train_over(landed, base)
    git("checkout", "-q", "-b", "origin-side", base)
    commit("elsewhere")
    git("merge", "-q", "--no-ff", "-m", "Merge pull request #1 from train/main-#{landed[0, 12]}", landed)
    git("update-ref", "refs/remotes/origin/main", "HEAD")
  end

  def forget_repository = FileUtils.remove_entry(File.dirname(repo))
end
