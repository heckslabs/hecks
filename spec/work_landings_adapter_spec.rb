require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/work_landings"

# The WorkLandings port's adapter answers a commit of a work item that `main` contains, read from
# git: the tip of the item's branch, a merge on main that names the branch, or a commit on main
# with a `Work:` trailer naming the item. It refuses by name when none is: a landing on a branch
# main never took is no landing, and a key written in prose names nothing.
RSpec.describe Hecks::Adapters::WorkLandings do
  let(:repo) { File.realpath(Dir.mktmpdir("work-landings")) }
  let(:adapter) { described_class.new(settings: { root: repo }) }
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }

  def git(*args) = Open3.capture2e("git", "-C", repo, *args).first.strip

  def commit(name, message = name)
    File.write(File.join(repo, name), name)
    git("add", name)
    git("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", message)
    git("rev-parse", "HEAD")
  end

  before do
    git("init", "-q", "-b", "main")
    commit("base")
  end

  after { FileUtils.remove_entry(repo) }

  it "answers the tip of the item's branch once main contains it", :aggregate_failures do
    git("checkout", "-qb", "fix-the-thing")
    tip = commit("a")
    git("checkout", "-q", "main")
    git("merge", "-q", "--ff-only", "fix-the-thing")

    expect(adapter.check_landing(work: { value: "fix-the-thing" })).to eq(landing: { value: tip })
  end

  it "answers a commit on main whose Work trailer names the item" do
    landed = commit("b", "Fix the thing\n\nWork: fix-the-thing")
    expect(adapter.check_landing(work: "fix-the-thing")).to eq(landing: { value: landed })
  end

  it "answers a merge on main that names the branch, after the branch is gone" do
    git("checkout", "-qb", "fix-the-thing")
    commit("e")
    git("checkout", "-q", "main")
    commit("f")
    git("-c", "user.name=t", "-c", "user.email=t@example.com", "merge", "-q", "--no-ff", "fix-the-thing",
        "-m", "Merge pull request #7 from acme/fix-the-thing")
    git("branch", "-qD", "fix-the-thing")
    expect(adapter.check_landing(work: "fix-the-thing")).to eq(landing: { value: git("rev-parse", "main") })
  end

  it "takes no commit that names the key only in prose, or a longer key in its trailer" do
    commit("c", "Say fix-the-thing in passing\n\nWork: fix-the-thing-again")
    expect { adapter.check_landing(work: "fix-the-thing") }.to raise_error(failure, /fix-the-thing has no landing on main/)
  end

  it "refuses a work item whose branch main does not contain" do
    git("checkout", "-qb", "fix-the-thing")
    commit("d")
    git("checkout", "-q", "main")
    expect { adapter.check_landing(work: "fix-the-thing") }.to raise_error(failure, /fix-the-thing has no landing on main/)
  end

  it "refuses a work item with no landing" do
    expect { adapter.check_landing(work: "w") }.to raise_error(failure, /w has no landing on main/)
  end
end
