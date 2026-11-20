# frozen_string_literal: true

require "open3"
require "tmpdir"
require "fileutils"

# A throwaway repository in which a branch and its target change one bluebook at the same spot,
# so git's line merge conflicts. Two coders adding different aggregates there is the case the
# merge fixer settles; the same aggregate changed twice is the case it refuses.
class BluebookConflictRepo
  # The bluebook both sides start from.
  BASE = "Hecks.bluebook \"S\" do\n  aggregate \"A\" do\n    attribute :x, String\n  end\nend\n"

  # @return [String] the repository's top level
  attr_reader :dir

  # @param prefix [String] the temporary directory's prefix
  def initialize(prefix = "hecks-settled")
    @dir = File.realpath(Dir.mktmpdir(prefix))
    git("init", "-q", "-b", "trunk")
    quiet_maintenance
    commit(BASE)
  end

  # @param name [String] the aggregate to add after `A`
  # @return [String] the base bluebook with that aggregate added
  def self.adding(name)
    BASE.sub("  end\nend", "  end\n\n  aggregate \"#{name}\" do\n    attribute :y, String\n  end\nend")
  end

  # Cuts `branch` from the current tip, commits `theirs` there, then commits `mine` on `trunk`,
  # and leaves `branch` checked out.
  #
  # @return [void]
  def diverge(branch, mine, theirs, file = "s.bluebook")
    git("checkout", "-q", "-b", branch)
    commit(theirs, file)
    git("checkout", "-q", "trunk")
    commit(mine, file)
    git("checkout", "-q", branch)
  end

  # As {#diverge}, with `branch` cut after a commit that `trunk` then carried by squash
  # ("Train: main at <sha>"), so a rebase replays only the branch's own commit.
  #
  # @return [void]
  def board_then_diverge(branch, mine, theirs)
    git("checkout", "-q", "-b", "local")
    commit("x\n", "carried.txt")
    boarded = git("rev-parse", "HEAD").strip
    git("checkout", "-q", "trunk")
    commit("x\n", "carried.txt", "Train: main at #{boarded}")
    git("checkout", "-q", "local")
    diverge(branch, mine, theirs)
  end

  # Installs a `pre-rebase` hook that refuses, so a rebase stops with no file in conflict.
  #
  # @return [void]
  def refuse_rebases
    hook = File.join(@dir, ".git", "hooks", "pre-rebase")
    File.write(hook, "#!/bin/sh\necho refused by the hook\nexit 1\n")
    File.chmod(0o755, hook)
  end

  # @param text [String] what the file holds
  # @param file [String] the file, from the top level
  # @param subject [String] the commit's subject
  # @return [String] git's output
  def commit(text, file = "s.bluebook", subject = "edit")
    File.write(File.join(@dir, file), text)
    git("add", ".")
    git("commit", "-q", "-m", subject)
  end

  # @return [String] git's output; raises when git fails
  def git(*)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *, chdir: @dir)
    raise out unless status.success?

    out
  end

  # @param file [String] the file, from the top level
  # @return [String] what it holds now
  def read(file = "s.bluebook") = File.read(File.join(@dir, file))

  # @return [void]
  def remove = FileUtils.remove_entry(@dir)

  private

  # Stops git from starting a background gc or maintenance after a commit, which would write
  # into the repository while the spec's teardown removes it.
  def quiet_maintenance
    git("config", "gc.auto", "0")
    git("config", "maintenance.auto", "false")
  end
end
