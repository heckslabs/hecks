require "hecks"
require "json"
require_relative "../../lib/hecks/hecks/adapters/github_pull_requests"

# Transport only: the runner is a recorder, so the suite never shells out to a real `gh`. The `gh`
# arguments and the answers are read for real.
RSpec.describe Hecks::Adapters::GithubPullRequests do
  subject(:pulls) { described_class.new(runner: runner) }

  let(:calls) { [] }
  let(:replies) { {} }
  let(:runner) do
    lambda do |args|
      calls << args
      replies.fetch(args) { ["", "no reply for #{args.inspect}", false] }
    end
  end

  def created = ["pr", "create", "--head", "feature", "--base", "main", "--fill"]

  describe "#create" do
    it "opens the pull request and answers its number and URL", :aggregate_failures do
      replies[created] = ["Creating pull request\nhttps://github.com/acme/app/pull/42\n", "", true]

      answer = pulls.create(branch: { value: "feature" }, base: { value: "main" })

      expect(answer[:outcome]).to eq(value: "opened")
      expect(answer[:number]).to eq(value: "42")
      expect(answer[:url]).to eq(value: "https://github.com/acme/app/pull/42")
    end

    it "defaults the base to main" do
      replies[created] = ["https://github.com/acme/app/pull/42\n", "", true]

      pulls.create(branch: { value: "feature" })

      expect(calls).to include(created)
    end

    it "refuses when no branch is named" do
      expect { pulls.create(base: { value: "main" }) }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /no branch/)
    end

    it "refuses with what gh said when it refuses" do
      replies[created] = ["", "a pull request for branch \"feature\" already exists", false]

      expect { pulls.create(branch: { value: "feature" }) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /already exists/)
    end
  end

  describe "#squash" do
    it "squash-merges the pull request by its number, and never passes --admin", :aggregate_failures do
      replies[["pr", "merge", "42", "--squash"]] = ["", "", true]

      expect(pulls.squash(number: { value: "42" })).to include(outcome: { value: "merged" })
      expect(calls).to eq([["pr", "merge", "42", "--squash"]])
    end

    it "refuses when no number is named" do
      expect { pulls.squash(number: nil) }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /no pull request number/)
    end

    it "refuses with what gh said when GitHub will not merge" do
      replies[["pr", "merge", "42", "--squash"]] = ["", "Pull request #42 is not mergeable", false]

      expect { pulls.squash(number: { value: "42" }) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /not mergeable/)
    end
  end

  describe "#status" do
    let(:view) do
      { "number" => 42, "state" => "OPEN", "url" => "https://github.com/acme/app/pull/42", "mergedAt" => nil,
        "statusCheckRollup" => [{ "name" => "rspec", "conclusion" => "SUCCESS" },
                                { "name" => "lint", "conclusion" => "", "state" => "PENDING" }] }
    end

    it "answers the state, URL, merge and checks as text" do
      replies[["pr", "view", "42", "--json", "number,state,url,mergedAt,statusCheckRollup"]] = [JSON.generate(view), "", true]

      expect(pulls.status(number: { value: "42" })[:text]).to eq(
        "number: 42\nstate: OPEN\nurl: https://github.com/acme/app/pull/42\nmerged: no\nchecks: rspec=SUCCESS, lint=PENDING\n"
      )
    end
  end
end
