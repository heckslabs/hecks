# frozen_string_literal: true

require "json"
require "open3"

# Builds a scratch repository with one linked worktree and runs the worktree nesting guard hook
# against a directory in it.
module NestingGuardHelpers
  # Makes a repository at `primary` with a commit, and a linked worktree at `linked`.
  def build_scratch_repo(primary, linked)
    FileUtils.mkdir_p(primary)
    git(primary, "init", "-q", "-b", "main")
    git(primary, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "base")
    git(primary, "worktree", "add", "-q", "-b", "outer", linked)
  end

  def git(where, *argv) = Open3.capture3("git", "-C", where, *argv)

  # @return [Array(String, Integer)] what the hook wrote to stderr, and its exit status
  def hook(tool, cwd, extra = {})
    input = JSON.generate({ tool_name: tool, cwd: cwd, tool_input: {} }.merge(extra))
    script = File.expand_path("../../.claude/hooks/worktree_nesting_guard.sh", __dir__)
    _out, err, status = Open3.capture3(script, stdin_data: input)
    [err, status.exitstatus]
  end
end
