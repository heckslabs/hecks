require "spec_helper"
require "hecks/agents/adapters/scratch_branches"
require_relative "support/scratch_branch_stand_in"

# The `ScratchBranches` adapter cuts a canary's scratch branch with `LinkedTree.add!`, applies the
# patch and commits it; a patch that does not apply is refused by its own words and its worktree
# retired. A stand-in runs each argv, so no git or launcher is touched.
RSpec.describe Hecks::Adapters::ScratchBranches do
  let(:stand_in) { ScratchBranchStandIn.new }
  let(:adapter) { described_class.new(run: stand_in.method(:call), root: stand_in.root) }
  let(:asked) { ScratchBranchStandIn::ASKED }

  after { stand_in.remove }

  it "answers the scratch commit, its worktree and the branch named for the round" do
    tree = File.join(stand_in.root, ".claude/worktrees/tidy-parse-3")
    expect(adapter.cut_scratch(**asked))
      .to eq(submission: { value: "abc123" }, checkout: { value: tree }, branch: { value: "tidy-parse-3" })
  end

  it "cuts the branch through LinkedTree.add! from the base" do
    adapter.cut_scratch(**asked)
    expect(stand_in.calls.first).to include("LinkedTree.add!", "branch.value=tidy-parse-3", "base.value=main")
  end

  context "when the patch does not apply" do
    let(:stand_in) { ScratchBranchStandIn.new(apply_ok: false) }

    it "refuses in the patch's own words" do
      expect { adapter.cut_scratch(**asked) }.to raise_error(described_class::Uncut, /\Athe patch does not apply/)
    end

    it "retires the empty worktree with Landing.retire!" do
      expect { adapter.cut_scratch(**asked) }.to raise_error(described_class::Uncut)
        .and(change { stand_in.calls.map { |argv| argv[1] }.include?("Landing.retire!") }.to(true))
    end
  end
end
