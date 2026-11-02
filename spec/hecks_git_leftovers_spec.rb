require "spec_helper"
require "hecks/hecks/adapters/git_leftovers"
require "tmpdir"
require "open3"

# After a push, the Leftovers port lists the worktrees of branches that landed and are still there,
# and says what a retirement would do with each. It removes nothing. Every example builds its own
# throwaway repository; the real one is never read.
RSpec.describe Hecks::Adapters::GitLeftovers do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-landing-leftovers")) }
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

  def build_repo(branch = "work/a", *files)
    FileUtils.mkdir_p(repo)
    git("init", "-b", "main")
    commit(repo, "README")
    git("worktree", "add", "-b", branch, tree)
    files.each { |file| commit(tree, file) }
  end

  def landed(*branches) = allow(Hecks::Adapters::LandedBranches).to receive(:of).and_return(branches)

  def report = landing.leftovers(checkout: repo).dig(:report, :value)

  def branch?(name) = !git("branch", "--list", name).strip.empty?

  it "names a landed worktree it would retire, and removes nothing", :aggregate_failures do
    build_repo("work/a", "a.rb")
    git("merge", "work/a")
    landed("work/a")

    expect(report).to include("work/a: would retire it")
    expect(File.directory?(tree)).to be(true)
    expect(branch?("work/a")).to be(true)
  end

  it "names a landed worktree it would keep, and why", :aggregate_failures do
    build_repo("work/a", "a.rb")
    git("merge", "work/a")
    File.write(File.join(tree, "scratch.txt"), "mine")
    landed("work/a")

    expect(report).to include("work/a: would keep it", "scratch.txt")
    expect(File.read(File.join(tree, "scratch.txt"))).to eq("mine")
  end

  it "keeps a landed branch that has commits main lacks, and says how many" do
    build_repo("work/a", "a.rb")
    landed("work/a")

    expect(report).to include("work/a: would keep it", "1 commit(s) not on main")
  end

  it "leaves a worktree that never landed out of the report", :aggregate_failures do
    build_repo("work/a")
    landed

    expect(report).not_to include("work/a")
    expect(File.directory?(tree)).to be(true)
  end

  it "skips a landed branch whose worktree is gone" do
    build_repo("work/a")
    landed("work/gone")

    expect(report).not_to include("work/gone")
  end

  it "says so when no landed worktree is left" do
    build_repo("work/a")
    landed

    expect(report).to eq("no landed worktree is left")
  end

  it "names each landed worktree on a line of its own" do
    build_repo("work/a", "a.rb")
    git("merge", "work/a")
    second = File.join(dir, "second")
    git("worktree", "add", "-b", "work/b", second)
    landed("work/a", "work/b")

    expect(report.lines.map(&:strip)).to eq(["work/a: would retire it", "work/b: would retire it"])
  end
end
