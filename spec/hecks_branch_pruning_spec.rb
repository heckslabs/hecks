require "spec_helper"
require "hecks/hecks/adapters/branch_pruning"
require "tmpdir"
require "open3"

# Each rule of branch pruning, on a scratch repository built under a temporary directory.
RSpec.describe Hecks::Adapters::BranchPruning do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-branch-pruning")) }
  let(:pruning) { described_class.new }
  let(:items) { {} }
  let(:landed) { ->(_key) { [] } }

  before do
    git("init", "-b", "main")
    commit("README")
  end

  after { FileUtils.remove_entry(dir) }

  def git(*args, chdir: dir)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out.strip
  end

  def commit(file, text = "x")
    File.write(File.join(dir, file), text)
    git("add", ".")
    git("commit", "-m", file)
  end

  def branch_with(name, file)
    git("checkout", "-b", name)
    commit(file)
    git("checkout", "main")
  end

  def verdict(name, **held)
    pruning.survey(checkout: dir, items: items, landed: landed, **held)[:verdicts].find { |v| v.branch == name }
  end

  def heads = git("for-each-ref", "--format=%(refname:short)", "refs/heads").split

  it "judges a branch whose commit main has by patch absorbed and deletes it" do
    branch_with("absorbed", "a.txt")
    git("cherry-pick", "absorbed")
    pruning.prune(checkout: dir)
    expect(heads).to eq(["main"])
  end

  it "keeps a branch with a commit main lacks, and files it when no item names it" do
    branch_with("floating", "f.txt")
    expect([verdict("floating").action, verdict("floating").filing[:title]]).to eq([:file, "absorb or drop floating"])
  end

  it "files the commits and diffstat, and never lands or deletes the branch" do
    branch_with("floating", "f.txt")
    filed = []
    pruning.prune(checkout: dir, filer: ->(**work) { filed << work })
    expect([heads.sort, filed.first[:detail]]).to match([%w[floating main], /f\.txt.*\n.*1 file changed/m])
  end

  it "files a branch once when its title is already filed" do
    branch_with("floating", "f.txt")
    filed = []
    pruning.prune(checkout: dir, filer: ->(**work) { filed << work }, filed: ["absorb or drop floating"])
    expect(filed).to be_empty
  end

  context "with a done item that landed under another name" do
    let(:items) { { "feature" => "done" } }

    it "deletes the branch when every landed commit is in main" do
      branch_with("feature-v2", "v2.txt")
      sha = git("rev-parse", "main")
      pruning.prune(checkout: dir, items: items, landed: ->(_key) { [sha] })
      expect(heads).to eq(["main"])
    end

    it "keeps it when the landing is not proven" do
      branch_with("feature", "v.txt")
      expect(verdict("feature").action).to eq(:keep)
    end

    it "keeps it when a landed commit is not in main" do
      branch_with("feature", "v.txt")
      other = git("rev-parse", "feature")
      expect(verdict("feature", landed: ->(_key) { [other] }).action).to eq(:keep)
    end
  end

  context "with an open item" do
    let(:items) { { "planned-one" => "planned", "started-one" => "started" } }

    it "names a planned item's branch for re-planning and keeps a started one" do
      branch_with("planned-one", "p.txt")
      branch_with("started-one", "s.txt")
      expect([verdict("planned-one").action, verdict("started-one").action]).to eq(%i[replan keep])
    end
  end

  context "with an early-CI mirror" do
    let(:sha) { "a" * 40 }

    it "deletes ci/ and -sha mirrors whose source is gone, and keeps them while it stands" do
      branch_with("ci/gone", "c.txt")
      branch_with("live-#{sha}", "l.txt")
      branch_with("live", "m.txt")
      expect([verdict("ci/gone").action, verdict("live-#{sha}").action]).to eq(%i[delete keep])
    end
  end

  it "keeps a branch a worktree holds, and survey removes nothing" do
    git("worktree", "add", "-b", "held", File.join(dir, "tree"))
    pruning.survey(checkout: dir)
    expect([heads.sort, verdict("held").action]).to eq([%w[held main], :keep])
  end

  it "keeps a branch that gained a commit after it was judged" do
    judged = absorbed_verdict
    git("checkout", "absorbed")
    commit("late.txt")
    expect(deleter.call(judged)).to start_with("kept absorbed")
  end

  def absorbed_verdict
    branch_with("absorbed", "a.txt")
    git("cherry-pick", "absorbed")
    verdict("absorbed")
  end

  def deleter
    git_adapter = Hecks::Adapters::Git.new
    reading = Hecks::Adapters::BranchPruning::Reading.new(git_adapter, dir)
    classifier = Hecks::Adapters::BranchPruning::Classifier.new(reading, items: {}, landed: landed)
    Hecks::Adapters::BranchPruning::Deleting.new(git_adapter, dir, classifier)
  end
end
