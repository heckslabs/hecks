require "spec_helper"
require "hecks/hecks/adapters/ci_runs"
require_relative "support/red_pull_request_host"

# A red train pull request whose failed jobs cannot be read stays watched, and says why.
RSpec.describe Hecks::Adapters::CiRuns, "#watch of a red pull request" do
  include RedPullRequestHost

  def watch(readable:)
    described_class.runner = host(readable: readable)
    described_class.new.watch(landed: tip, checkout: Dir.pwd)
  end

  after { described_class.runner = nil }

  it "answers running when the failed jobs answer 502" do
    expect(watch(readable: false)[:outcome][:value]).to eq("running")
  end

  it "names the unreadable failure in the report" do
    expect(watch(readable: false)[:report][:value]).to include("failed jobs unreadable", "502", "retrying")
  end

  it "answers pr_failed on the next observation once the jobs are readable" do
    watch(readable: false)
    expect(watch(readable: true)[:outcome][:value]).to eq("pr_failed")
  end
end
