require "tmpdir"
require "fileutils"
require "open3"

# A real repository in a temporary directory whose main holds `origin/main` and some landings.
module RevertLandingRepo
  def work = @work ||= File.join(File.realpath(Dir.mktmpdir("git_train_revert")), "work")

  def git(*)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *, chdir: work)
    raise out unless status.success?

    out.strip
  end

  # Lands a branch that writes one file, as a merge commit on main.
  def land(name)
    git("checkout", "-q", "-b", name)
    File.write(File.join(work, "#{name}.txt"), name)
    git("add", ".")
    git("commit", "-q", "-m", name)
    git("checkout", "-q", "main")
    git("merge", "-q", "--no-ff", "-m", "land #{name}", name)
    git("rev-parse", "HEAD")
  end

  def start_repo
    FileUtils.mkdir_p(work)
    git("init", "-q", "-b", "main")
    git("config", "user.name", "t")
    git("config", "user.email", "t@t")
    git("commit", "-q", "--allow-empty", "-m", "first")
    git("update-ref", "refs/remotes/origin/main", "HEAD")
  end

  def exists?(name) = File.exist?(File.join(work, "#{name}.txt"))

  def failure = Hecks::Adapters::ConsoleCapture::Failure

  def revert(sha, **) = Hecks::Adapters::GitTrain::Reverting.new(Hecks::Adapters::Git.new, work).revert(sha, **)

  # Lands a branch, then edits its file on main so reverting it conflicts; answers main's head.
  def edit_landed(name)
    land(name)
    File.write(File.join(work, "#{name}.txt"), "later")
    git("commit", "-q", "-am", "edit")
    git("rev-parse", "HEAD")
  end
end
