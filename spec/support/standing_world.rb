# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "open3"
require "hecks/pipeline_board/adapters/pipeline_stages"

# A scratch repository with an origin, for the specs of where a change stands: the primary
# checkout on `main`, `origin/main` behind or level with it, and worktrees cut from it.
class StandingWorld
  attr_reader :root

  def initialize(base)
    @base = base
    @root = File.join(base, "repo")
    git(base, "init", "--bare", "-b", "main", "origin.git")
    git(base, "clone", "origin.git", "repo")
    configure
    commit(@root, "base.txt", "base")
    git(@root, "push", "origin", "main")
  end

  def worktree(branch)
    path = File.join(@base, "wt-#{branch}")
    git(@root, "worktree", "add", "-b", branch, path, "main")
    configure(path)
    path
  end

  def commit(dir, file, text)
    File.write(File.join(dir, file), text)
    git(dir, "add", file)
    git(dir, "commit", "-m", "add #{file}")
  end

  def standing_of(branch)
    git = Hecks::Adapters::PipelineGit.new(root: @root, settings: { ttl: 0 })
    board = Hecks::Adapters::PipelineStages.new(root: @root, settings: { readers: { git: git } })
    board.standing.find { |row| row[:branch] == branch }
  end

  def push = git(@root, "push", "origin", "main")

  def pick(branch) = git(@root, "cherry-pick", git(@root, "rev-parse", branch).strip)

  def git(dir, *args)
    out, status = Open3.capture2e("git", "-C", dir, *args)
    raise "git #{args.join(" ")}: #{out}" unless status.success?

    out
  end

  private

  def configure(dir = @root)
    git(dir, "config", "user.email", "a@example.test")
    git(dir, "config", "user.name", "A")
  end
end
