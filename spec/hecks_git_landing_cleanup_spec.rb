require "spec_helper"
require "hecks/hecks/adapters/git_landing"
require "tmpdir"
require "open3"

# A landing tidies up after itself, and refuses a branch that changes ground another started Work
# item holds. Every example builds its own throwaway repository; the real repository is never read.
RSpec.describe Hecks::Adapters::GitLanding do
  let(:dir) { Dir.mktmpdir("hecks-landing-spec") }
  let(:repo) { File.join(dir, "main") }
  let(:tree) { File.join(dir, "tree") }
  let(:landing) { described_class.new }

  after { FileUtils.remove_entry(dir) }

  def git(*args, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out
  end

  def commit(where, file, text = "x")
    FileUtils.mkdir_p(File.dirname(File.join(where, file)))
    File.write(File.join(where, file), text)
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

  def land = landing.merge(checkout: repo, branch: "work/a")

  def report = land.dig(:report, :value)

  def holds(key, *area)
    allow(Hecks::Adapters::StartedWork).to receive(:items).and_return([{ key: key, area: area }])
  end

  it "removes the worktree and deletes the branch once they are on main", :aggregate_failures do
    build_repo("lib/a.rb")
    report

    expect(File.exist?(tree)).to be(false)
    expect(git("branch", "--list", "work/a")).to eq("")
  end

  it "says what it removed" do
    build_repo("lib/a.rb")

    expect(report).to include("removed", "deleted work/a")
  end

  def build_on_main_checkout
    FileUtils.mkdir_p(repo)
    git("init", "-b", "main")
    commit(repo, "README")
    git("checkout", "-b", "work/a")
    commit(repo, "lib/a.rb")
  end

  it "keeps a branch whose worktree is the main checkout", :aggregate_failures do
    build_on_main_checkout

    expect(report).to include("kept work/a")
    expect(git("branch", "--list", "work/a")).to include("work/a")
  end

  it "keeps a worktree that holds uncommitted work", :aggregate_failures do
    build_repo("lib/a.rb")
    allow(landing).to receive(:refuse_unsaved)
    File.write(File.join(tree, "scratch.txt"), "unsaved")

    expect(report).to include("kept work/a", "uncommitted")
    expect(File.exist?(tree)).to be(true)
  end

  it "keeps a branch that has commits main lacks" do
    build_repo("lib/a.rb")
    merger = instance_double(described_class::Merger, land: { report: { value: "landed" } })
    allow(described_class::Merger).to receive(:new).and_return(merger)

    expect(report).to include("kept work/a", "not on main")
  end

  it "refuses a branch that changes files another started work item holds, naming both", :aggregate_failures do
    build_repo("lib/hecks/tickets/a.rb")
    holds("work/other", "lib/hecks/tickets")

    expect { land }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, %r{lib/hecks/tickets/a.rb.*work/other})
    expect(File.exist?(tree)).to be(true)
  end

  it "lands a branch whose changes are outside every other work item's area" do
    build_repo("lib/a.rb")
    holds("work/other", "spec")

    expect(report).to include("onto main")
  end

  it "does not count the landing's own work item as a rival" do
    build_repo("lib/a.rb")
    holds("work/a", "lib")

    expect(report).to include("onto main")
  end
end
