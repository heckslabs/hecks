# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/gh_rest"

# GhRest answers a pull request, its checks and the open pull requests from REST reads, in the
# shapes `gh pr view --json` gave, and reads every page of a list.
RSpec.describe Hecks::Adapters::GhRest do
  let(:pull) do
    { "number" => 9, "state" => "closed", "html_url" => "https://x/pull/9", "created_at" => "2026-11-15T00:00:00Z",
      "head" => { "ref" => "train/main-abc", "sha" => "s9" }, "merged_at" => nil, "merge_commit_sha" => "m9" }
  end
  let(:runs) { Array.new(130) { |index| { "name" => "job#{index}", "status" => "completed", "conclusion" => "success" } } }
  let(:status) { { "context" => "ci/legacy", "state" => "failure", "target_url" => "https://x/s" } }

  # A `gh` that answers by endpoint; the check runs come as two pages, as `--slurp` hands them.
  def reader(pulls: [pull])
    lambda do |*args|
      path = args.last
      return pulls if path.include?("per_page=30")
      return [pulls] if path.include?("pulls?state=all")
      return [{ "check_runs" => runs.first(100) }, { "check_runs" => runs.drop(100) }] if path.include?("check-runs")

      answer(path)
    end
  end

  def answer(path)
    return [{ "statuses" => [status] }] if path.include?("/status")
    return [[{ "sha" => "c1", "commit" => { "message" => "fix it\n\nmore" } }]] if path.include?("/commits?")

    [[{ "body" => "hecks: note" }]]
  end

  def read(**options) = described_class.new(reader(**options)).pull("train/main-abc")

  it "counts every check run of every page" do
    expect(read["statusCheckRollup"].count { |entry| entry.key?("status") }).to eq(130)
  end

  it "carries a status-only context as a state entry" do
    expect(read["statusCheckRollup"].last).to eq("context" => "ci/legacy", "state" => "FAILURE", "targetUrl" => "https://x/s")
  end

  it "reads a closed unmerged pull request as CLOSED with no merge commit", :aggregate_failures do
    expect(read).to include("state" => "CLOSED", "mergeCommit" => nil, "createdAt" => "2026-11-15T00:00:00Z")
    expect(read["commits"]).to eq([{ "oid" => "c1", "messageHeadline" => "fix it" }])
  end

  it "reads a merged pull request as MERGED with its merge commit" do
    merged = pull.merge("merged_at" => "2026-11-15T01:00:00Z")
    expect(read(pulls: [merged])).to include("state" => "MERGED", "mergeCommit" => { "oid" => "m9" })
  end

  it "answers nil when the branch has no pull request" do
    expect(read(pulls: [])).to be_nil
  end

  it "reads the checks of the train pull requests only, and no other" do
    listed = [pull, pull.merge("number" => 4, "head" => { "ref" => "feature/x", "sha" => "s4" })]
    rows = described_class.new(reader(pulls: listed)).open_pulls(30, "train/")
    expect(rows.map { |row| row.key?("statusCheckRollup") }).to eq([true, false])
  end
end
