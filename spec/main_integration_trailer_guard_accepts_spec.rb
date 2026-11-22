# frozen_string_literal: true

require "spec_helper"
require_relative "support/trailer_repo"

# The landing accepts a range whose own commits name their run, and what is exempt.
RSpec.describe "a landing accepts commits that name their run" do
  include TrailerRepo

  let(:work) { Dir.mktmpdir("hecks-trailer-guard") }

  after { FileUtils.rm_rf(work) }

  it "accepts a commit carrying both trailers" do
    start
    commit_file("a", "change\n\nHecks-Run: run-1\nHecks-Work: some-item")
    expect(refusal).to be_nil
  end

  it "accepts an owner's commit with only Hecks-Run: owner" do
    start
    commit_file("a", "change\n\nHecks-Run: owner")
    expect(refusal).to be_nil
  end

  it "does not ask a merge commit for trailers" do
    start
    land_side("change\n\nHecks-Run: run-1\nHecks-Work: some-item")
    expect(refusal).to be_nil
  end

  it "asks nothing of a repository whose commit-msg hook does not write trailers" do
    start(hook: false)
    commit_file("a", "change")
    expect(refusal).to be_nil
  end

  it "asks nothing before the cutoff names a moment" do
    start(cutoff: nil)
    commit_file("a", "change")
    expect(refusal).to be_nil
  end

  it "does not ask a commit authored before the cutoff" do
    start(cutoff: 2_000)
    commit_file("a", "change", at: 1_500)
    expect(refusal).to be_nil
  end
end
