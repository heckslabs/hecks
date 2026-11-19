require "spec_helper"
require_relative "support/settled_finish"

# A landing's finish rebases the branch onto its target. When two coders added different
# aggregates at the same spot of one bluebook, the merge fixer settles the conflict by declaration
# and the finish goes on to its gate; when it cannot, the finish refuses as the vendored one does,
# with the fixer's reason added. Every example builds its own throwaway repository.
RSpec.describe Hecks::Adapters::Landing::SettledRebase::Finisher, "#rebase settled" do
  include SettledFinish

  let(:repo) { BluebookConflictRepo.new }
  let(:base) { BluebookConflictRepo::BASE }

  after { repo.remove }

  it "finishes a branch whose bluebook conflict merges by declaration, both aggregates kept" do
    repo.diverge("adds-c", adding("B"), adding("C"))
    finish
    expect(repo.read).to include("aggregate \"B\"", "aggregate \"C\"")
  end

  it "settles the conflict on the boarded path, replaying only the branch's own commit" do
    repo.board_then_diverge("adds-c", adding("B"), adding("C"))
    finish
    expect(repo.git("log", "--format=%s", "trunk..adds-c").lines.size).to eq(1)
  end
end
