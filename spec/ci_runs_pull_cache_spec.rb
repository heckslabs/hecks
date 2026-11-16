# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/ci_runs/pull_cache"

# PullCache keeps one read of a pull request for a few seconds, so a loop of reads costs one.
RSpec.describe Hecks::Adapters::CiRuns::PullCache do
  let(:now) { [0] }
  let(:cache) { described_class.new(clock: -> { now.first }, keep: 15) }

  def reads_for(branch, times)
    count = 0
    times.each { cache.read(branch) { count += 1 } }
    count
  end

  it "reads once for a burst of asks inside the window" do
    expect(reads_for("train/main-a", 1..40)).to eq(1)
  end

  it "reads again once the window has passed" do
    cache.read("train/main-a") { :old }
    now[0] = 16
    expect(cache.read("train/main-a") { :new }).to eq(:new)
  end

  it "keeps branches apart" do
    cache.read("train/main-a") { :a }
    expect(cache.read("train/main-b") { :b }).to eq(:b)
  end

  it "reads again after it is cleared" do
    cache.read("train/main-a") { :old }
    cache.clear
    expect(cache.read("train/main-a") { :new }).to eq(:new)
  end
end
