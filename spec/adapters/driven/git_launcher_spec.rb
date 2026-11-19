require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "hecks/hecks/adapters/git_launcher"

# The Launcher port's adapter moves the push train's copy to the commit a push or a merged train
# pull request recorded, never backwards, links the boarding checkout's local files into it, and
# leaves any copy that is not a detached, clean checkout of the same repository alone.
# Real repositories in a temporary directory: an origin, the checkout that pushes, the launcher.
RSpec.describe Hecks::Adapters::GitLauncher do
  let(:dir) { File.realpath(Dir.mktmpdir("git_launcher")) }
  let(:origin) { File.join(dir, "origin.git") }
  let(:work) { File.join(dir, "work") }
  let(:launcher) { File.join(dir, "launcher") }

  # What a moved launcher reports: its short commit before and after.
  MOVED = /\Alauncher \h+ -> \h+; /

  after { FileUtils.rm_rf(dir) }

  def git(*args, chdir: dir)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out.strip
  end

  def commit_and_push(message)
    git("commit", "-q", "--allow-empty", "-m", message, chdir: work)
    git("push", "-q", "origin", "HEAD:main", chdir: work)
    git("rev-parse", "HEAD", chdir: work)
  end

  def set_up
    git("init", "-q", "--bare", "-b", "main", origin)
    git("clone", "-q", origin, work)
    commit_and_push("first")
    git("clone", "-q", origin, launcher)
    git("checkout", "-q", "--detach", chdir: launcher)
  end

  def refresh(pushed)
    described_class.new(root: launcher).refresh(checkout: { value: work }, remote: { value: "origin" },
                                                pushed: { value: pushed })
  end

  it "moves a detached, clean checkout of the same repository to the pushed commit", :aggregate_failures do
    set_up
    pushed = commit_and_push("second")
    expect(refresh(pushed)[:report][:value]).to match(MOVED)
    expect(git("rev-parse", "HEAD", chdir: launcher)).to eq(pushed)
  end

  it "never moves the copy backwards to an older commit", :aggregate_failures do
    set_up
    first = git("rev-parse", "HEAD", chdir: work)
    refresh(commit_and_push("second"))
    expect(refresh(first)[:report][:value]).to start_with("launcher at")
    expect(git("rev-parse", "HEAD", chdir: launcher)).not_to eq(first)
  end

  it "links the boarding checkout's local files into the copy" do
    set_up
    world = File.join(work, "lib/hecks/hecks/pipeline.local.world")
    FileUtils.mkdir_p(File.dirname(world)) && File.write(world, "# world\n")
    refresh(commit_and_push("second"))
    expect(File.readlink(File.join(launcher, "lib/hecks/hecks/pipeline.local.world"))).to eq(world)
  end

  it "names no live copy under the spec runner when no root is given" do
    adapter = described_class.new(env: { "HECKS_WRITES_LOCAL" => "1" })
    expect(adapter.refresh(pushed: { value: "abc" })[:report][:value]).to eq("launcher left: the spec runner names no train copy")
  end

  it "leaves a copy that is on a branch" do
    set_up
    git("checkout", "-q", "main", chdir: launcher)
    expect(refresh(commit_and_push("second"))[:report][:value]).to end_with("on a branch, not detached")
  end

  it "leaves a copy with local edits" do
    set_up
    File.write(File.join(launcher, "edit.txt"), "x")
    expect(refresh(commit_and_push("second"))[:report][:value]).to end_with("has local edits (?? edit.txt)")
  end

  it "leaves a copy of another repository" do
    set_up
    git("remote", "set-url", "origin", File.join(dir, "elsewhere.git"), chdir: launcher)
    expect(refresh(commit_and_push("second"))[:report][:value]).to end_with("a checkout of another repository")
  end
end
