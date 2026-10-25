require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/git_landing"
require "hecks/hecks/adapters/git_checkout"

# The Checkout and Landing adapters, against a throwaway repository: a landing fast-forwards or
# merges onto main and reports a conflict, a retirement keeps unmerged or dirty work, and the
# reads say where a checkout stands. The real checkout is never touched.
RSpec.describe "the Checkout and Landing adapters", :io do
  let(:scratch) { File.realpath(Dir.mktmpdir("hecks-landing")) }
  let(:main_tree) { File.join(scratch, "main") }
  let(:feature_tree) { File.join(scratch, "feature") }
  let(:landing) { Hecks::Adapters::GitLanding.new }
  let(:checkout) { Hecks::Adapters::GitCheckout.new }

  def git(*args, dir: main_tree)
    out, err, status = Open3.capture3("git", *args, chdir: dir)
    raise "git #{args.join(" ")} failed: #{err}" unless status.success?

    out.strip
  end

  def commit(name, dir:, text: name)
    File.write(File.join(dir, name), text)
    git("add", name, dir: dir)
    git("commit", "-q", "-m", name, dir: dir)
  end

  def land(**held) = landing.merge(checkout: { value: feature_tree }, **held)

  def retire(**held) = landing.remove(checkout: { value: feature_tree }, **held)

  before do
    FileUtils.mkdir_p(main_tree)
    git("init", "-q", "-b", "main")
    git("config", "user.name", "A")
    git("config", "user.email", "a@example.test")
    commit("first", dir: main_tree)
    git("worktree", "add", "-q", "-b", "feat/x", feature_tree)
  end

  after { FileUtils.remove_entry(scratch) }

  it "fast-forwards main onto a branch that is ahead", :aggregate_failures do
    commit("second", dir: feature_tree)

    expect(land).to include(outcome: { value: "fast_forwarded" })
    expect(git("rev-parse", "main")).to eq(git("rev-parse", "feat/x", dir: feature_tree))
  end

  it "merges when main moved, keeping both lines", :aggregate_failures do
    commit("second", dir: feature_tree)
    commit("elsewhere", dir: main_tree)

    expect(land).to include(outcome: { value: "merged" })
    expect(git("log", "--format=%s", "-n", "1", "--merges")).to include("feat/x")
  end

  it "reports a conflict, leaves main as it was and aborts the merge", :aggregate_failures do
    commit("same", dir: feature_tree, text: "theirs")
    commit("same", dir: main_tree, text: "ours")
    before = git("rev-parse", "main")

    expect { land }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /conflicts in same/)
    expect([git("rev-parse", "main"), git("status", "--porcelain")]).to eq([before, ""])
  end

  it "lands onto main when no worktree has it checked out", :aggregate_failures do
    commit("second", dir: feature_tree)
    git("checkout", "-q", "--detach")

    expect(land).to include(outcome: { value: "fast_forwarded" })
    expect(git("rev-parse", "main")).to eq(git("rev-parse", "feat/x", dir: feature_tree))
  end

  it "refuses to land a worktree that holds uncommitted work" do
    commit("second", dir: feature_tree)
    File.write(File.join(feature_tree, "loose"), "x")

    expect { land }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /uncommitted work/)
  end

  it "retires a merged worktree and deletes its branch", :aggregate_failures do
    commit("second", dir: feature_tree)
    land
    retire

    expect(File.directory?(feature_tree)).to be(false)
    expect(git("branch", "--list", "feat/x")).to eq("")
  end

  it "refuses to retire a branch with commits main lacks" do
    commit("second", dir: feature_tree)

    expect { retire }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /1 commit\(s\) not on main/)
  end

  it "refuses to retire a worktree with uncommitted work" do
    File.write(File.join(feature_tree, "loose"), "x")

    expect { retire }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /uncommitted work/)
  end

  it "refuses to retire the primary worktree" do
    expect { landing.remove(checkout: { value: main_tree }, branch: "main") }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /primary worktree/)
  end

  it "lists the branches whose commits are not on main", :aggregate_failures do
    commit("second", dir: feature_tree)
    text = landing.unlanded(checkout: { value: main_tree })[:text]

    expect(text).to include("feat/x", "1 commit(s) not on main", feature_tree)
  end

  it "says everything is on main once a branch is landed" do
    expect(landing.unlanded(checkout: { value: main_tree })[:text]).to eq("everything is on main\n")
  end

  it "reports the branch, the worktree kind and the changed paths", :aggregate_failures do
    File.write(File.join(feature_tree, "loose"), "x")
    text = checkout.status(checkout: { value: feature_tree })[:text]

    expect(text).to include("branch: feat/x", "worktree: linked", "main: ahead 0, behind 0", "?? loose")
  end

  it "reports what a checkout changed since main, as a stat or as names", :aggregate_failures do
    commit("second", dir: feature_tree)

    expect(checkout.changes(checkout: { value: feature_tree })[:text]).to include("second", "1 file changed")
    expect(checkout.changes(checkout: { value: feature_tree }, names_only: true)[:text]).to eq("second\n")
  end

  it "reports the commits of a range, and refuses what is not one", :aggregate_failures do
    commit("second", dir: feature_tree)

    expect(checkout.log(checkout: { value: feature_tree }, range: "main..HEAD")[:text]).to match(/\A\h+ second\n\z/)
    expect { checkout.log(checkout: { value: feature_tree }, range: "--all") }.to raise_error(Hecks::Runtime::NotFound)
  end
end
