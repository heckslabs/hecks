require "spec_helper"
require "fileutils"
require "hecks/hecks/adapters/git_train"
require_relative "support/revert_landing_repo"

# Why a reopened Work item is told to revert the revert: once a landing is reverted, main still
# holds the branch's commits, so merging or rebasing the old branch brings in nothing, while a
# branch that reverts the revert and adds a commit brings the change back. The repository is a
# throwaway one.
RSpec.describe "reverted work landing again" do
  include RevertLandingRepo

  before do
    start_repo
    @revert = revert(land("one"))[:reverted]
  end

  after { FileUtils.rm_rf(File.dirname(work)) }

  # Lands a branch cut from main that reverts the revert and adds one commit.
  def land_the_fix
    git("checkout", "-q", "-b", "one-again")
    git("revert", "--no-edit", @revert)
    File.write(File.join(work, "fix.txt"), "fix")
    git("add", ".")
    git("commit", "-q", "-m", "fix")
    git("checkout", "-q", "main")
    git("merge", "-q", "--no-ff", "-m", "land one-again", "one-again")
  end

  it "brings in nothing when the old branch is merged again", :aggregate_failures do
    expect(git("merge", "--no-ff", "one")).to include("Already up to date")
    expect(exists?("one")).to be(false)
  end

  it "replays nothing when the old branch is rebased onto main", :aggregate_failures do
    git("checkout", "-q", "one")
    git("rebase", "-q", "main")
    expect(git("rev-parse", "one")).to eq(git("rev-parse", "main"))
    expect(exists?("one")).to be(false)
  end

  it "brings the change back when the fix reverts the revert and adds a commit" do
    land_the_fix
    expect([exists?("one"), exists?("fix")]).to eq([true, true])
  end
end
