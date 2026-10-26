require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "hecks/hecks/adapters/git_launcher"

# The Launcher port's adapter moves the copy of Hecks that runs the push train to the commit it
# pushed, and leaves any copy that is not a detached, clean checkout of the same repository alone.
# Real repositories in a temporary directory: an origin, the checkout that pushes, the launcher.
RSpec.describe Hecks::Adapters::GitLauncher do
  let(:dir) { File.realpath(Dir.mktmpdir("git_launcher")) }
  let(:origin) { File.join(dir, "origin.git") }
  let(:work) { File.join(dir, "work") }
  let(:launcher) { File.join(dir, "launcher") }

  # What a moved launcher reports: its short commit before and after.
  MOVED = /\Alauncher \h+ -> \h+\z/

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
