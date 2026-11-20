# frozen_string_literal: true

require "spec_helper"
require "support/train_scratch_repo"
require "hecks/signalbox/adapters/looking"

# The push train's copy is the designated source of the pressure beat. It sits detached at an
# ancestor of local main between fast-forwards, and its beat must still be cleared.
RSpec.describe Hecks::Adapters::Looking::View do
  include TrainScratchRepo

  let(:copy) { File.join(Dir.mktmpdir("beat-copies"), "hecks-train") }

  before do
    git("init", "-q", "-b", "main")
    commit("first")
    git("worktree", "add", "-q", "--detach", copy, "HEAD")
    commit("second")
  end

  it "clears the beat from the train copy one commit behind local main" do
    facts = described_class.new(copy).facts

    expect(facts[:head]).to eq(facts[:main])
  end

  it "still refuses a worktree that is not the train copy and is behind main" do
    other = File.join(Dir.mktmpdir("beat-copies"), "feature")
    git("worktree", "add", "-q", "--detach", other, "HEAD~1")
    facts = described_class.new(other).facts

    expect(facts[:head]).not_to eq(facts[:main])
  end
end
