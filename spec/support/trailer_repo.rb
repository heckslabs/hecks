# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/main_boarding"

# A repository where origin/main is one commit behind a branch, built in a temporary directory,
# and the trailer guard read over it.
module TrailerRepo
  MAIN_INTEGRATION = Hecks::Adapters::MainIntegration

  def git(*)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *, chdir: work)
    raise out unless status.success?

    out
  end

  def commit_file(name, message, at: nil)
    File.write(File.join(work, name), name)
    git("add", ".")
    git("commit", "-q", "-m", message, *("--date=@#{at} +0000" if at))
  end

  # A repository whose hook writes the trailers when `hook` is true, and whose commits are asked
  # for them from the epoch second `cutoff`, when one is given.
  def start(hook: true, cutoff: 0)
    git("init", "-q", "-b", "main")
    FileUtils.mkdir_p(File.join(work, ".githooks"))
    File.write(File.join(work, ".githooks", "commit-msg"), "#!/bin/sh\n# Hecks-Run\n") if hook
    File.write(File.join(work, ".githooks", "trailers_from"), "#{cutoff}\n") if cutoff
    commit_file("base", "start", at: 1)
    git("update-ref", "refs/remotes/origin/main", "HEAD")
  end

  def land_side(message)
    git("checkout", "-q", "-b", "side")
    commit_file("a", message)
    git("checkout", "-q", "main")
    git("merge", "--no-ff", "-q", "-m", "Land side", "side")
  end

  def guard = MAIN_INTEGRATION::TrailerGuard.new(MAIN_INTEGRATION::Repository.new(work))

  def refusal
    guard.check!("origin/main", "HEAD")
    nil
  rescue Hecks::Adapters::ConsoleCapture::Failure => e
    e.message
  end
end
