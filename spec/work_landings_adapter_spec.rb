require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/work_landings"

# The WorkLandings port's adapter answers the first landed commit of a work item that `main`
# contains, and refuses by name when none is: a landing on a branch main never took is no landing.
RSpec.describe Hecks::Adapters::WorkLandings do
  let(:repo) { File.realpath(Dir.mktmpdir("work-landings")) }
  let(:adapter) { described_class.new(settings: { root: repo }) }
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }

  def git(*args) = Open3.capture2e("git", "-C", repo, *args).first.strip

  def commit(name)
    File.write(File.join(repo, name), name)
    git("add", name)
    git("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", name)
    git("rev-parse", "HEAD")
  end

  def landings(*shas)
    items = instance_double(Hecks::Adapters::Dispatching::WorkItems, landed_commits: shas)
    allow(Hecks::Adapters::Dispatching::WorkItems).to receive(:new).and_return(items)
  end

  before { git("init", "-q", "-b", "main") }

  after { FileUtils.remove_entry(repo) }

  it "answers the landed commit main contains" do
    landings(commit("a"))
    expect(adapter.check_landing(work: { value: "w" })).to eq(landing: { value: git("rev-parse", "main") })
  end

  it "refuses a work item whose landing main does not contain" do
    commit("a")
    git("checkout", "-qb", "aside")
    landings(commit("b"))
    expect { adapter.check_landing(work: "w") }.to raise_error(failure, /w has no landing on main/)
  end

  it "refuses a work item with no landing" do
    commit("a")
    landings
    expect { adapter.check_landing(work: "w") }.to raise_error(failure, /w has no landing on main/)
  end
end
