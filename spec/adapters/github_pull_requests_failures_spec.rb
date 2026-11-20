# frozen_string_literal: true

require "hecks"
require_relative "../../lib/hecks/hecks/adapters/github_pull_requests"
require_relative "../support/failed_checks_github"

# Transport only: the runner is a recorder, so the suite never shells out to a real `gh`. The `gh`
# arguments and the answers are read for real.
RSpec.describe Hecks::Adapters::GithubPullRequests, "#failures" do
  include FailedChecksGithub

  subject(:pulls) { described_class.new(runner: runner) }

  def failures(number = "42") = pulls.failures(number: { value: number })

  context "when a job's specs failed" do
    before { stage_spec_failure }

    it "names the failed job, its steps and its failing examples", :aggregate_failures do
      expect(failures.size).to eq(1)
      expect(failures.first).to include(job: "specs (1)", steps: "specs (1)/Run specs", examples: "spec/widget_spec.rb:12")
    end

    it "answers the message of the first failure, without what gh puts before each line" do
      expect(failures.first[:error]).to eq("expected: 3 got: 2")
    end

    it "names the newest commit touching the failing specs as the culprit" do
      expect(failures.first[:culprit]).to eq("newest commit touching the failing specs: aaaaaaaaaa Count the parts")
    end

    it "says so when no commit touches the failing specs" do
      reply_files("aaaaaaaaaaaa1111", "notes.txt")

      expect(failures.first[:culprit]).to eq("not attributed: none of the 2 newest commits touches the failing specs")
    end

    it "makes only read calls, never a write", :aggregate_failures do
      failures

      expect(calls.first).to eq(view_call)
      expect(calls.flatten.join(" ")).not_to match(/merge|edit|close|reopen|rerun|--admin|-X|POST|PATCH|PUT|DELETE/)
    end
  end

  context "when a job failed before the specs ran" do
    before { stage_setup_failure }

    it "answers no example, the error line and no attribution", :aggregate_failures do
      expect(failures.first).to include(steps: "specs (1)/Set up Ruby", examples: "", error: "Error: the gem server timed out")
      expect(failures.first[:culprit]).to eq("not attributed: no spec failed by name")
    end

    it "reads no commit" do
      failures

      expect(calls.map(&:first)).not_to include("api")
    end
  end

  it "answers no row, and reads no run, when no check failed", :aggregate_failures do
    reply_view([check("lint", "SUCCESS", "900")], [])

    expect(failures).to eq([])
    expect(calls).to eq([view_call])
  end

  it "refuses a number that is not a pull request, and reads no run", :aggregate_failures do
    replies[view_call("7")] = ["", "no pull requests found with number 7", false]

    expect { failures("7") }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /no pull requests found/)
    expect(calls).to eq([view_call("7")])
  end

  it "refuses a number that gh would read as an option", :aggregate_failures do
    expect { failures("--admin") }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /not a number/)
    expect(calls).to be_empty
  end
end
