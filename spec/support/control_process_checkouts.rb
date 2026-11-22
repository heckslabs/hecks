require "tmpdir"
require "fileutils"

# A primary checkout with a launcher and a Gemfile, and a linked worktree under it, in a
# temporary directory: what the control process specs run against.
module ControlProcessCheckouts
  # @return [String] the temporary directory the checkouts live in
  def dir = (@dir ||= Dir.mktmpdir("control-process"))

  # @return [String] the primary checkout's real path
  def primary = File.realpath(File.join(dir, "primary"))

  # @return [String] the linked worktree, as made (not resolved)
  def worktree_dir = File.join(dir, "primary", ".claude", "worktrees", "topic")

  # @return [String] the linked worktree's real path
  def own = File.realpath(worktree_dir)

  # Makes the primary (launcher and Gemfile) and the worktree whose `.git` file names the primary.
  #
  # @return [void]
  def build_checkouts
    FileUtils.mkdir_p([File.join(dir, "primary", "exe"), worktree_dir])
    FileUtils.touch([File.join(dir, "primary", "exe", "hecks"), File.join(dir, "primary", "Gemfile")])
    link_worktree(File.join(dir, "primary", ".git", "worktrees", "topic"))
  end

  # @return [void]
  def link_worktree(admin)
    FileUtils.mkdir_p(admin)
    File.write(File.join(admin, "commondir"), "../..\n")
    File.write(File.join(worktree_dir, ".git"), "gitdir: #{admin}\n")
  end

  # @return [void]
  def remove_checkouts = FileUtils.rm_rf(dir)
end
