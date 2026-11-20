# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "open3"
require "hecks/hecks/adapters/codebase/tree_facts"

# The repositories the tree-facts specs read: a primary checkout on main under a temp directory,
# and the linked worktrees cut from it.
module TreeFactsRepos
  # Runs git in a directory of the temp repository.
  def git(*args, chdir: primary)
    _out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise "git #{args.join(" ")} failed" unless status.success?
  end

  # @return [String] the primary checkout, on main with one commit
  def primary
    path = File.join(@dir, "primary")
    return path if Dir.exist?(path)

    Dir.mkdir(path)
    git("init", "-q", "-b", "main", chdir: path)
    git("commit", "-q", "--allow-empty", "-m", "first", chdir: path)
    path
  end

  # @return [String] a linked worktree of the primary checkout, on the branch or detached
  def linked_worktree(branch = nil)
    path = File.join(@dir, branch || "detached")
    git("worktree", "add", "-q", *(branch ? ["-b", branch] : ["--detach"]), path)
    path
  end
end

# The git facts a Codebase run's examine reports about its tree: whether it is a linked worktree,
# and which branch it has checked out.
RSpec.describe Hecks::Adapters::Codebase::TreeFacts do
  include TreeFactsRepos

  around { |example| Dir.mktmpdir("tree-facts") { |dir| (@dir = dir) && example.run } }

  it "reports the primary checkout on main as not linked" do
    expect(described_class.of(primary)).to eq(linked: { value: false }, branch: { value: "main" })
  end

  it "reports a coder's worktree as linked, on its branch" do
    expect(described_class.of(linked_worktree("coder-work"))).to eq(linked: { value: true }, branch: { value: "coder-work" })
  end

  it "reports a detached linked tree on HEAD" do
    expect(described_class.of(linked_worktree)).to eq(linked: { value: true }, branch: { value: "HEAD" })
  end

  it "reports a tree outside git as not linked, on HEAD" do
    expect(described_class.of(@dir)).to eq(linked: { value: false }, branch: { value: "HEAD" })
  end

  it "answers the check's name with every fact present" do
    expect(described_class.answer(@dir, "gate", "quick")).to include(check_name: { value: "gate-quick" })
  end
end
