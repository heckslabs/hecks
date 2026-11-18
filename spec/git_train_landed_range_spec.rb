# frozen_string_literal: true

require "spec_helper"
require_relative "support/train_scratch_repo"
require "hecks/hecks/adapters/git"
require "hecks/hecks/adapters/git_train"

# A train is landed when its tip is the commit the landing's gate marker names as green and it holds
# the remote's main.
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

  it "qualifies a range whose tip the marker names" do
    mark(head)

    expect(range.landed?(head, "origin-main")).to be(true)
  end

  it "qualifies a fast-forwarded range of plain commits whose tip the marker names" do
    commit("fast-forwarded")
    mark(head)

    expect(range.landed?(head, "origin-main")).to be(true)
  end

  it "does not qualify a tip the remote main does not descend to" do
    mark(git("rev-parse", "HEAD~1"))

    expect(range.landed?(git("rev-parse", "HEAD~1"), "main")).to be(false)
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
