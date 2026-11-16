# frozen_string_literal: true

require "spec_helper"
require "json"
require "hecks/hecks/adapters/github_pull_requests/train_sweep"

# The sweep lists the open pull requests through REST, so it spends no GraphQL budget.
RSpec.describe Hecks::Adapters::GithubPullRequests::TrainSweep do
  let(:calls) { [] }
  let(:github) do
    lambda do |*args|
      calls << args
      "[]"
    end
  end

  it "reads the open list with `gh api`, never `gh pr list`" do
    described_class.new(github, ->(_args) { [true, ""] }).run
    expect(calls.map(&:first)).to all(eq("api"))
  end
end
