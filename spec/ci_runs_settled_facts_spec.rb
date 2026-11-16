# frozen_string_literal: true

require "spec_helper"
require "securerandom"
require "hecks/hecks/adapters/ci_runs"
require_relative "support/fake_train_github"
require_relative "support/private_settled_facts"

# A red train pull request's failure is read from its settled CI run once, however many beats
# watch it; a rerun starts new jobs, so it is read again.
RSpec.describe Hecks::Adapters::CiRuns, "#watch of a settled failure" do
  include_context "with private settled facts"

  let(:github) { FakeTrainGithub.new }
  let(:landed) { SecureRandom.hex(20) }

  def job_check(job)
    { "name" => "rspec", "status" => "COMPLETED", "conclusion" => "FAILURE",
      "detailsUrl" => "https://github.com/o/r/actions/runs/77/job/#{job}" }
  end

  before do
    github.rollup = [job_check(1)]
    described_class.runner = github
  end

  after { described_class.runner = nil }

  # A beat is a new process, which holds no pull request read from the one before.
  def beat
    Hecks::Adapters::CiRuns::PullCache.shared.clear
    described_class.new.watch(landed: landed, checkout: Dir.pwd)
  end

  def run_reads = github.calls.grep(/\Agh run (view|list)/).size

  it "reads the run's jobs on the first beat" do
    beat
    expect(run_reads).to be_positive
  end

  it "makes no run read on the nine beats after the first", :aggregate_failures do
    beat
    first = run_reads
    outcomes = Array.new(9) { beat[:outcome][:value] }
    expect(run_reads).to eq(first)
    expect(outcomes.uniq).to eq(["pr_failed"])
  end

  it "keeps the same report on every beat" do
    reports = Array.new(2) { beat[:report][:value] }
    expect(reports.uniq.size).to eq(1)
  end

  it "reads again once a rerun has started new jobs" do
    beat
    first = run_reads
    github.rollup = [job_check(2)]
    beat
    expect(run_reads).to be > first
  end
end
