require "spec_helper"
require_relative "support/settled_finish"

# The merge train rebases each ready branch onto the target, which moved as the branches before it
# landed, so two branches finished against an older target can meet here in a bluebook conflict
# no finish saw. The merge fixer settles it by declaration, or the train skips the branch with the
# fixer's reason. Every example builds its own throwaway repository.
RSpec.describe Hecks::Adapters::Landing::SettledRebase::Train, "#rebase" do
  let(:repo) { BluebookConflictRepo.new }
  let(:base) { BluebookConflictRepo::BASE }
  let(:ticket) { instance_double(landing::Ticket, data: { branch: "adds-c", checkout: repo.dir }, update: nil, deliver: nil) }
  let(:line) { instance_double(landing::Line).tap { |line| allow(line).to receive(:next_ready).and_return(ticket, nil) } }
  let(:crew) { landing::Train::Crew.new(line, instance_double(landing::Ticket), ->(*) { { landed: true } }, ->(_dir) {}) }

  def landing = Hecks::Adapters::GitLanding

  after { repo.remove }

  def run_train = landing::Train.new(Hecks::Adapters::Git.new, repo.dir, crew, onto: "trunk").run

  it "lands a branch whose bluebook conflict merges by declaration" do
    repo.diverge("adds-c", BluebookConflictRepo.adding("B"), BluebookConflictRepo.adding("C"))
    expect(run_train).to eq("landed adds-c")
  end

  it "skips a branch whose declaration both sides changed, with the fixer's reason" do
    repo.diverge("adds-c", base.sub(":x", ":mine"), base.sub(":x", ":theirs"))
    expect(run_train).to end_with("; the merge fixer refused: s.bluebook: aggregate A changed on both sides")
  end
end
