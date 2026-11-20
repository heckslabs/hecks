require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "hecks/hecks/adapters/git_train"
require_relative "../../support/revert_landing_repo"

RSpec.describe Hecks::Adapters::GitTrain::Reverting, "#revert" do
  include RevertLandingRepo

  before { start_repo }

  after { FileUtils.rm_rf(File.dirname(work)) }

  it "reverts only the named landing, with a new commit on top", :aggregate_failures do
    one = land("one")
    land("two")
    answer = revert(one)
    expect([exists?("one"), exists?("two")]).to eq([false, true])
    expect([git("rev-list", "--count", "#{one}..HEAD"), answer[:report]]).to match(["3", /brings in nothing/])
  end

  it "opens the report with the reason and names the revert commit in full", :aggregate_failures do
    report = revert(land("one"), reason: "one broke a spec.")[:report]
    expect(report).to start_with("one broke a spec. It was reverted as #{git("rev-parse", "HEAD")}.")
    expect(report).to include("revert that revert", "Never rebase or re-merge the old branch")
  end

  it "refuses a commit that is not a landing" do
    land("one")
    expect { revert(git("rev-parse", "HEAD~1")) }.to raise_error(failure, /not a landing/)
  end

  it "refuses a dirty checkout and changes nothing", :aggregate_failures do
    one = land("one")
    File.write(File.join(work, "one.txt"), "edited")
    expect { revert(one) }.to raise_error(failure, /staged or modified/)
    expect(git("rev-parse", "HEAD")).to eq(one)
  end

  it "aborts a conflicting revert and leaves main where it was", :aggregate_failures do
    head = edit_landed("one")
    expect { revert("HEAD~1") }.to raise_error(failure, /conflicts/)
    expect([git("rev-parse", "HEAD"), git("status", "--porcelain")]).to eq([head, ""])
  end
end
