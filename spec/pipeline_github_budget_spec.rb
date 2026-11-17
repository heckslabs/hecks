# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_stages"
require_relative "support/rest_pull_view"

# The board does not spend a GitHub budget that is nearly spent: it makes no call that would, and
# says on its cards when reads resume.
RSpec.describe Hecks::Adapters::PipelineGitHub, "#open_prs under a spent budget" do
  let(:reset) { Time.parse("2026-11-15T01:05:00").to_i }
  let(:calls) { [] }

  def limits(core: 4000, graphql: 4000)
    { "resources" => { "core"    => { "limit" => 5000, "remaining" => core, "reset" => reset },
                       "graphql" => { "limit" => 5000, "remaining" => graphql, "reset" => reset } } }
  end

  def listed = [{ "number" => 7, "headRefName" => "train/main-abc", "createdAt" => "2026-11-15T00:00:00Z" }]

  # A fake `gh` that counts every call and answers the rate limit and one open pull request.
  def reader(standing)
    open = RestPullView.open_gh(-> { listed })
    lambda do |*args|
      calls << args
      args[1] == "rate_limit" ? standing : open.call(*args)
    end
  end

  def board(standing) = described_class.new(settings: { gh: reader(standing), ttl: 0 })

  it "reads the open pull requests with a budget to spare", :aggregate_failures do
    expect(board(limits).open_prs).to include(count: 1, train: 7)
    expect(calls.map(&:first).uniq).to eq(["api"])
  end

  it "makes no call but the free rate limit when the budget is at 5 percent", :aggregate_failures do
    expect { board(limits(core: 250)).open_prs }.to raise_error(Hecks::Adapters::PipelineBoard::Unavailable)
    expect(calls).to eq([%w[api rate_limit]])
  end

  it "says when reads resume" do
    expect { board(limits(core: 250)).open_prs }.to raise_error(/GitHub reads paused until 01:05/)
  end

  it "holds back a GraphQL read when the GraphQL budget is spent, and lets REST through", :aggregate_failures do
    budget = Hecks::Adapters::PipelineBoard::Budget.new(-> { limits(graphql: 250) })
    expect { budget.check!(%w[pr list]) }.to raise_error(/paused until/)
    expect { budget.check!(%w[run list]) }.not_to raise_error
  end

  it "takes the share that must remain from its setting" do
    budget = Hecks::Adapters::PipelineBoard::Budget.new(-> { limits(core: 1000) }, percent: 25)
    expect { budget.check!(%w[run list]) }.to raise_error(/paused until/)
  end

  it "reads on when the rate limit cannot be read" do
    budget = Hecks::Adapters::PipelineBoard::Budget.new(-> { raise Hecks::Adapters::PipelineBoard::Unavailable, "down" })
    expect { budget.check!(%w[run list]) }.not_to raise_error
  end
end
