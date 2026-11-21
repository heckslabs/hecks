# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"
require "tmpdir"

# The EnterWorktree guard hook, run against a scratch repository with one linked worktree: a session
# standing in a linked worktree is refused a new worktree and told to keep working where it is, a
# session in the primary checkout is let through, and so is every other tool. A session with no role
# (the owner's) is covered like any other.
RSpec.describe "the worktree nesting guard hook" do
  let(:root) { File.expand_path("..", __dir__) }
  let(:dir) { File.realpath(Dir.mktmpdir("nesting_guard")) }
  let(:primary) { File.join(dir, "primary") }
  let(:linked) { File.join(primary, ".claude/worktrees/outer") }

  before do
    FileUtils.mkdir_p(primary)
    git(primary, "init", "-q", "-b", "main")
    git(primary, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "base")
    git(primary, "worktree", "add", "-q", "-b", "outer", linked)
  end

  after { FileUtils.remove_entry(dir) }

  def git(where, *argv) = Open3.capture3("git", "-C", where, *argv)

  # @return [Array(String, Integer)] what the hook wrote to stderr, and its exit status
  def hook(tool, cwd, extra = {})
    input = JSON.generate({ tool_name: tool, cwd: cwd, tool_input: {} }.merge(extra))
    _out, err, status = Open3.capture3(File.join(root, ".claude/hooks/worktree_nesting_guard.sh"), stdin_data: input)
    [err, status.exitstatus]
  end

  it "refuses EnterWorktree from a linked worktree, naming the fix", :aggregate_failures do
    err, code = hook("EnterWorktree", linked)
    expect(code).to eq(2)
    expect(err).to include("keep working in this worktree", "#{primary}/.claude/worktrees")
  end

  it "lets EnterWorktree run from the primary checkout" do
    expect(hook("EnterWorktree", primary)).to eq(["", 0])
  end

  it "lets another tool run from a linked worktree" do
    expect(hook("Bash", linked, tool_input: { command: "ls" })).to eq(["", 0])
  end

  it "lets the call through when the directory is not a repository" do
    expect(hook("EnterWorktree", dir)).to eq(["", 0])
  end
end
