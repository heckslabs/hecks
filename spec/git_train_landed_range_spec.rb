# frozen_string_literal: true

require "spec_helper"
require_relative "support/train_scratch_repo"
require "hecks/hecks/adapters/git"
require "hecks/hecks/adapters/git_train"

# A train is landed when every first-parent commit it holds is a merge and its tip is the commit the
# landing's gate marker names as green.
RSpec.describe Hecks::Adapters::GitTrain::LandedRange, :io do
  include TrainScratchRepo

  let(:range) { described_class.new(Hecks::Adapters::Git.new, repo) }

  before do
    git("init", "-q", "-b", "main")
    commit("first")
    git("branch", "origin-main")
    land("one")
    land("two")
  end

  after { FileUtils.remove_entry(repo) }

  it "qualifies a range of landed merges whose tip the marker names" do
    mark(head)

    expect(range.landed?(head, "origin-main")).to be(true)
  end

  it "does not qualify a range that holds a hand commit" do
    commit("by-hand")
    mark(head)

    expect(range.landed?(head, "origin-main")).to be(false)
  end

  it "does not qualify a tip the marker does not name" do
    mark(git("rev-parse", "HEAD~1"))

    expect(range.landed?(head, "origin-main")).to be(false)
  end

  it "does not qualify a marker that is not green" do
    mark(head, verdict: "red")

    expect(range.landed?(head, "origin-main")).to be(false)
  end

  it "does not qualify when no marker was written" do
    expect(range.landed?(head, "origin-main")).to be(false)
  end
end
