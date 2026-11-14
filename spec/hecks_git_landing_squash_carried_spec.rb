require "spec_helper"
require "tmpdir"
require "open3"
require "hecks/hecks/adapters/delivery_library"
Hecks::Adapters::DeliveryLibrary.require("git_landing")
Hecks::Adapters::DeliveryLibrary.require("git_worktree_add")

# Retiring a worktree whose branch reached main inside a squash-merged train: the branch's commits
# are no ancestors of main and no single patch matches them, yet the boarded commit the squash
# names holds them and the squash's tree. Every example builds throwaway repositories on a local
# bare remote.
RSpec.describe Hecks::Adapters::GitLanding, "#remove" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-retire-squash")) }
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }

  after { FileUtils.remove_entry(dir) }

  def repo = File.join(dir, "repo")

  def other = File.join(dir, "other")

  def tree = File.join(dir, "tree")

  def git(*args, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out.strip
  end

  def commit(where, file, content = file)
    File.write(File.join(where, file), content)
    git("add", ".", chdir: where)
    git("commit", "-m", file, chdir: where)
  end

  before do
    git("init", "--bare", "-b", "main", File.join(dir, "remote.git"), chdir: dir)
    git("clone", File.join(dir, "remote.git"), repo, chdir: dir)
    git("checkout", "-B", "main")
    commit(repo, "README")
    git("push", "origin", "main")
    git("clone", File.join(dir, "remote.git"), other, chdir: dir)
  end

  # The branch takes a.txt and b.txt, lands on local main by fast-forward, and main is boarded.
  def land_branch
    git("worktree", "add", "-b", "work/a", tree)
    %w[a.txt b.txt].each { |file| commit(tree, file) }
    git("merge", "--ff-only", "work/a")
    git("rev-parse", "main")
  end

  # The origin merges the train as one commit titled for the boarded sha, holding `files`.
  def squash(boarded, files = { "a.txt" => "a.txt", "b.txt" => "b.txt" })
    files.each { |file, content| File.write(File.join(other, file), content) }
    git("add", ".", chdir: other)
    git("commit", "-m", "Train: main at #{boarded[0, 9]} (#1)", chdir: other)
    git("push", "origin", "main", chdir: other)
  end

  def pull_main = Hecks::Adapters::GitWorktreeAdd.new.pull(checkout: repo)[:report][:value]

  def carried_branch
    squash(land_branch)
    pull_main
  end

  def retire = described_class.new.remove(checkout: tree, branch: "work/a", onto: "main")

  def branch? = !git("branch", "--list", "work/a").empty?

  it "retires a branch of two commits whose train origin squash-merged", :aggregate_failures do
    expect(carried_branch).to include("carried by squash: 2 commits")
    expect(retire.dig(:report, :value)).to include("and deleted work/a")
    expect(File.exist?(tree)).to be(false)
    expect(branch?).to be(false)
  end

  it "keeps a branch with a commit the train did not carry, naming that commit", :aggregate_failures do
    carried_branch
    commit(tree, "c.txt")
    expect { retire }.to raise_error(failure, /it has 1 commit\(s\) not on main: \h{9} c\.txt\z/)
    expect(branch?).to be(true)
  end

  it "keeps a carried branch whose worktree holds uncommitted work", :aggregate_failures do
    carried_branch
    File.write(File.join(tree, "draft.txt"), "unsaved")
    expect { retire }.to raise_error(failure, /holds uncommitted work.*draft\.txt/)
    expect(File.exist?(File.join(tree, "draft.txt"))).to be(true)
  end

  # The title names the boarded sha, but the squash's b.txt differs from the branch's.
  def squash_of_another_tree
    squash(land_branch, { "a.txt" => "a.txt", "b.txt" => "other text" })
    git("fetch", "--quiet", "origin")
    git("reset", "--hard", "origin/main")
  end

  it "keeps a branch when the squash titled for its boarded commit holds another tree", :aggregate_failures do
    squash_of_another_tree
    expect { retire }.to raise_error(failure, /it has 2 commit\(s\) not on main: \h{9} a\.txt, \h{9} b\.txt\z/)
    expect(branch?).to be(true)
  end
end
