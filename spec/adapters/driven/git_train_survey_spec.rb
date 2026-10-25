require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "hecks/hecks/adapters/git_train"

# A survey lists the checkouts under a directory whose branch holds commits its remote does not.
# Real repositories in a temporary directory: an origin and the checkouts cloned beside each other.
RSpec.describe Hecks::Adapters::GitTrain::Survey do
  let(:dir) { File.realpath(Dir.mktmpdir("git_train_survey")) }
  let(:root) { File.join(dir, "projects") }

  # How a checkout with unpushed commits is reported: its name, branch and counts.
  AHEAD = /\Aahead \(main\): 1 ahead, 0 behind — newest \h+ .*: unpushed\z/

  after { FileUtils.rm_rf(dir) }

  def git(*args, chdir: dir)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out.strip
  end

  def checkout(name)
    origin = File.join(dir, "#{name}.git")
    git("init", "-q", "--bare", "-b", "main", origin)
    path = File.join(root, name)
    git("clone", "-q", origin, path)
    git("commit", "-q", "--allow-empty", "-m", "first", chdir: path)
    git("push", "-q", "origin", "HEAD:main", chdir: path)
    path
  end

  def report = described_class.new(Hecks::Adapters::Git.new, root, remote: "origin").report

  before { FileUtils.mkdir_p(root) }

  it "names a checkout whose branch has a commit its remote does not, with its counts" do
    git("commit", "-q", "--allow-empty", "-m", "unpushed", chdir: checkout("ahead"))
    checkout("level")
    expect(report).to match(AHEAD)
  end

  it "says so when nothing waits to push" do
    checkout("level")
    expect(report).to eq("nothing to push under #{root}")
  end

  it "passes over a checkout that has no such remote" do
    git("init", "-q", "-b", "main", File.join(root, "local_only"))
    expect(report).to eq("nothing to push under #{root}")
  end
end
