require "spec_helper"
require "hecks/hecks/adapters/delivery_library"
Hecks::Adapters::DeliveryLibrary.require("git_landing")
require "tmpdir"
require "open3"

# `Landing.retire!` run from the main checkout with only a branch finds that branch's worktree and
# never takes the main checkout as the tree to remove. Each example builds its own scratch repo.
RSpec.describe Hecks::Adapters::GitLanding, "#remove from the main checkout" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-retire-main")) }
  let(:repo) { File.join(dir, "main") }
  let(:tree) { File.join(dir, "tree") }
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }

  after { FileUtils.remove_entry(dir) }

  def git(*args, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out
  end

  def commit(where, file)
    File.write(File.join(where, file), "x")
    git("add", ".", chdir: where)
    git("commit", "-m", file, chdir: where)
  end

  def build_repo(*files)
    FileUtils.mkdir_p(repo)
    git("init", "-b", "main")
    commit(repo, "README")
    git("worktree", "add", "-b", "work/a", tree)
    files.each { |file| commit(tree, file) }
  end

  def retire(**held) = described_class.new(scratch: ["tmp"]).remove(checkout: repo, onto: "main", **held)

  def plant_scratch
    FileUtils.mkdir_p(File.join(repo, "tmp"))
    File.write(File.join(repo, "tmp", "keep.txt"), "x")
  end

  def branch?(name) = !git("branch", "--list", name).strip.empty?

  it "takes the branch's worktree when the path given is the main checkout", :aggregate_failures do
    build_repo("a.rb")
    git("merge", "work/a")

    expect(retire(branch: "work/a").dig(:checkout, :value)).to eq(tree)
    expect(File.exist?(tree)).to be(false)
    expect(branch?("work/a")).to be(false)
  end

  it "finds the branch's worktree from the main checkout it runs in, and says what it removed" do
    build_repo("a.rb")
    git("merge", "work/a")
    said = Dir.chdir(repo) { described_class.new.remove(branch: "work/a").dig(:report, :value) }

    expect(said).to include("removed #{tree}", "deleted work/a")
  end

  it "refuses the main checkout by name", :aggregate_failures do
    build_repo("a.rb")

    expect { retire(branch: "main") }.to raise_error(failure, /main checkout/)
    expect(File.directory?(repo)).to be(true)
  end

  it "removes the linked worktree named by path from the main checkout", :aggregate_failures do
    build_repo("a.rb")
    git("merge", "work/a")

    expect(retire(checkout: tree, branch: "work/a").dig(:checkout, :value)).to eq(tree)
    expect(File.exist?(tree)).to be(false)
  end

  it "leaves the main checkout's scratch in place when it refuses the main checkout", :aggregate_failures do
    build_repo("a.rb")
    plant_scratch
    expect { retire(branch: "main") }.to raise_error(failure, /main checkout/)
    expect(File.exist?(File.join(repo, "tmp", "keep.txt"))).to be(true)
  end

  it "refuses a branch no linked worktree holds and keeps the main checkout", :aggregate_failures do
    build_repo
    git("branch", "work/b")
    expect { retire(branch: "work/b") }.to raise_error(failure, /no linked worktree has it checked out/)
    expect(branch?("work/b")).to be(true)
  end

  it "refuses a worktree whose tip main lacks and names Landing.discard!", :aggregate_failures do
    build_repo("a.rb")

    expect { retire(branch: "work/a") }.to raise_error(failure, /not on main.*Landing\.discard!/)
    expect(File.directory?(tree)).to be(true)
  end
end
