require "spec_helper"
require_relative "support/settled_finish"

# A landing's finish whose rebase the merge fixer cannot settle refuses as the vendored finish does,
# its refusal first, with the fixer's reason added when it has one. Every example builds its own
# throwaway repository.
RSpec.describe Hecks::Adapters::Landing::SettledRebase::Finisher, "#rebase refused" do
  include SettledFinish

  let(:repo) { BluebookConflictRepo.new }
  let(:base) { BluebookConflictRepo::BASE }

  after { repo.remove }

  it "refuses the same declaration changed on both sides, naming it, and leaves the branch", :aggregate_failures do
    repo.diverge("adds-c", base.sub(":x", ":mine"), base.sub(":x", ":theirs"))
    expect(refusal).to eq("conflict: rebasing adds-c onto trunk conflicts in s.bluebook; nothing changed; " \
                          "the merge fixer refused: s.bluebook: aggregate A changed on both sides")
    expect(repo.read).to include(":theirs")
  end

  it "refuses a conflict in a file that is not a bluebook with the vendored refusal first" do
    repo.diverge("adds-c", "mine\n", "theirs\n", "notes.txt")
    expect(refusal).to start_with("conflict: rebasing adds-c onto trunk conflicts in notes.txt; nothing changed; " \
                                  "the merge fixer refused: notes.txt is not a bluebook")
  end

  it "refuses a rebase that stops with no conflicted file with the vendored refusal alone" do
    repo.diverge("adds-c", adding("B"), adding("C"))
    repo.refuse_rebases
    expect(refusal).to match(/\Aconflict: rebasing adds-c onto trunk failed: .*; nothing changed\z/m)
  end
end
