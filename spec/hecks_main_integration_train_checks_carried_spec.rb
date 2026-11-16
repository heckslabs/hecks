require "spec_helper"
require_relative "support/carried_repository"

# A run whose commit origin/main already carries (an ancestor, or inside a squash train) does not
# hold the line; one it does not carry still does. The repository is a throwaway one.
RSpec.describe Hecks::Adapters::MainIntegration::TrainChecks do
  include CarriedRepository

  after { forget_repository }

  def blocked_by(landed)
    run = Hecks::Adapters::MainIntegration::Runs::Run.new(landed, "ci_running", repo)
    described_class.new(->(*, **) { [false, ""] }).blocking([run])
  end

  it "does not hold the line for a run origin/main contains" do
    open_repository
    git("update-ref", "refs/remotes/origin/main", "HEAD")
    expect(blocked_by(git("rev-parse", "HEAD"))).to be_nil
  end

  it "does not hold the line for a run a squash train on origin/main carries" do
    open_repository
    landed = git("rev-parse", "HEAD")
    squash_train_over(landed)
    expect(blocked_by(landed)).to be_nil
  end

  it "holds the line for a run origin/main does not carry" do
    open_repository
    git("update-ref", "refs/remotes/origin/main", "HEAD")
    expect(blocked_by(commit("later"))&.first&.landed).to eq(git("rev-parse", "HEAD"))
  end

  it "holds the line when there is no origin/main" do
    expect(blocked_by(open_repository)).not_to be_nil
  end
end
