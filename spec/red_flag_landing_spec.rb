require "spec_helper"
require "hecks/hecks/adapters/git_landing"
require "hecks/hecks/adapters/red_flagging"
require "tmpdir"
require "open3"

# While main is red, a landing is refused by name unless it is the fix of a red Work item, and it
# resumes when the flag is lowered. Every example builds its own throwaway repository.
RSpec.describe Hecks::Adapters::GitLanding, "#merge under a red flag" do
  let(:dir) { Dir.mktmpdir("hecks-red-flag-landing") }
  let(:repo) { File.join(dir, "main") }
  let(:flagging) { Hecks::Adapters::RedFlagging.new(checkout: repo) }

  after { FileUtils.remove_entry(dir) }

  def git(*args, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out
  end

  def branch_with_commit(name)
    tree = File.join(dir, name.tr("/", "_"))
    git("worktree", "add", "-b", name, tree)
    File.write(File.join(tree, "#{name.tr("/", "_")}.txt"), "x")
    git("add", ".", chdir: tree)
    git("commit", "-m", name, chdir: tree)
  end

  def build_repo(*branches)
    FileUtils.mkdir_p(repo)
    git("init", "-b", "main")
    File.write(File.join(repo, "README"), "x")
    git("add", ".")
    git("commit", "-m", "first")
    branches.each { |name| branch_with_commit(name) }
  end

  def raise_flag = flagging.hoist(commit: "abcdef1234567", detail: "abc: run 7 failure; failed jobs: rspec")

  def land(branch) = described_class.new.merge(checkout: repo, branch: branch)

  def landed? = git("branch", "--merged", "main")

  it "lands a branch while main is not flagged" do
    build_repo("feature-x")

    expect(land("feature-x").dig(:outcome, :value)).to eq("fast_forwarded")
  end

  it "refuses a branch while main is red, naming the flag", :aggregate_failures do
    build_repo("feature-x")
    raise_flag

    expect { land("feature-x") }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /main is red: flag flag-abcdef1234/)
    expect(landed?).not_to include("feature-x")
  end

  it "lands the fix of a red Work item while main is red" do
    build_repo("red-ci-fuzz")
    raise_flag

    expect(land("red-ci-fuzz").dig(:outcome, :value)).to eq("fast_forwarded")
  end

  it "records the fix's tip on the flag for the train", :aggregate_failures do
    build_repo("red-ci-fuzz")
    raise_flag
    land("red-ci-fuzz")

    expect(Hecks::Adapters::RedFlagMarker.new(File.join(repo, ".git")).read["fix_tip"]).to eq(git("rev-parse", "main").strip)
  end

  it "resumes landing once the flag is lowered", :aggregate_failures do
    build_repo("feature-x")
    raise_flag
    flagging.lower

    expect(land("feature-x").dig(:outcome, :value)).to eq("fast_forwarded")
  end
end
