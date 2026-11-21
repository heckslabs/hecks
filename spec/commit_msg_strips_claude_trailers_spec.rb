# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"
require "fileutils"

# Runs git in a temporary repository that uses the repo's own `.githooks` as its hooks path.
module CommitMsgRepo
  IDENTITY = { "GIT_AUTHOR_NAME" => "A", "GIT_AUTHOR_EMAIL" => "a@x.test",
               "GIT_COMMITTER_NAME" => "A", "GIT_COMMITTER_EMAIL" => "a@x.test" }.freeze

  def git(*) = Open3.capture3(IDENTITY, "git", *, chdir: work)

  def commit(message)
    git("commit", "-q", "--allow-empty", "-m", message)
    git("log", "-1", "--format=%B").first
  end
end

# The commit-msg hook strips Claude attribution trailers from a message and never refuses.
RSpec.describe "the commit-msg hook", :io do
  include CommitMsgRepo

  let(:work) { Dir.mktmpdir("hecks-commit-msg") }
  let(:both) { "Add thing\n\nBody.\n\nCo-Authored-By: Claude <x@y.test>\nClaude-Session: abc\n" }

  before do
    git("init", "-q")
    git("config", "core.hooksPath", File.expand_path("../.githooks", __dir__))
  end

  after { FileUtils.rm_rf(work) }

  it "removes both Claude trailers and the trailing blank lines" do
    expect(commit(both)).to eq("Add thing\n\nBody.\n\n")
  end

  it "leaves a message without them unchanged" do
    expect(commit("Plain\n\nBody.")).to eq("Plain\n\nBody.\n\n")
  end

  it "keeps a Co-Authored-By line that names someone else" do
    expect(commit("Pair\n\nCo-Authored-By: Sam <s@y.test>")).to include("Co-Authored-By: Sam")
  end

  it "lets the commit through" do
    expect(git("commit", "-q", "--allow-empty", "-m", both)[2]).to be_success
  end
end
