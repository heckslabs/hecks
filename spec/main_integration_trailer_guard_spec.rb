# frozen_string_literal: true

require "spec_helper"
require_relative "support/trailer_repo"

# The landing refuses a range whose commits do not name the run and work item behind them.
RSpec.describe "a landing refuses commits that do not name their run" do
  include TrailerRepo

  let(:work) { Dir.mktmpdir("hecks-trailer-guard") }

  before { start }

  after { FileUtils.rm_rf(work) }

  it "refuses a commit with no Hecks-Run trailer, by name" do
    commit_file("a", "change\n\nHecks-Work: some-item")
    expect(refusal).to include("Hecks-Run")
  end

  it "refuses an agent's commit with no Hecks-Work trailer, by name" do
    commit_file("a", "change\n\nHecks-Run: run-1")
    expect(refusal).to include("Hecks-Work")
  end

  it "refuses a commit authored after the cutoff, by name" do
    git("update-ref", "refs/remotes/origin/main", "HEAD")
    commit_file("b", "late", at: 3_000)
    expect(refusal).to include("late")
  end
end
