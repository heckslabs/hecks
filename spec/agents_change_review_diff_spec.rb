require "spec_helper"
require "hecks/agents/adapters/submitted_paths"

# The `Diff` query the architect reads through its door for a change review: git's diff of the
# commit's design files against main, read from the primary checkout, which outlives the worktree.
RSpec.describe Hecks::Adapters::SubmittedPaths, "#diff" do
  def status = instance_double(Process::Status, success?: true)

  def adapter(calls)
    git = lambda do |argv|
      calls << argv
      [argv.include?("--git-common-dir") ? "/primary/.git\n" : "diff --git a/x.bluebook\n", "", status]
    end
    described_class.new(git: git)
  end

  it "answers git's diff as the document's text" do
    expect(adapter([]).diff(review: { value: "abc1234" })).to eq(text: "diff --git a/x.bluebook\n")
  end

  it "reads the design files' diff against main from the primary checkout" do
    calls = []
    adapter(calls).diff(review: "abc1234")
    expect(calls.last).to eq(["git", "-C", "/primary", "diff", "main...abc1234", "--", *described_class::DESIGN])
  end

  it "finds the primary checkout from the common git directory beside its own bluebook" do
    calls = []
    adapter(calls).diff(review: "abc1234")
    expect(calls.first).to eq(["git", "-C", described_class::BLUEBOOK_DIR, "rev-parse", "--path-format=absolute",
                               "--git-common-dir"])
  end
end
