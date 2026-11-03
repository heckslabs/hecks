require "spec_helper"
require "json"
require "hecks/ci_speed/adapters/ci_reader"

# The sha-keyed read of CiReader: remote CI's verdict on one commit of main, read from the runs
# `gh`
# reports for it. `gh` is stubbed, so no run is started and nothing is read from GitHub.
RSpec.describe Hecks::Adapters::CiReader, "#head" do
  let(:sha) { "a" * 40 }
  let(:repo) { "heckslabs/embryonaut_platform" }
  let(:reader) { described_class.new(root: Dir.pwd) }

  # Answers `gh run list` with `runs` and `gh run view <id>` with that run's jobs.
  def answer_gh(runs:, jobs: {})
    allow(Open3).to receive(:capture3) do |*argv, **|
      out = argv[2] == "list" ? runs.to_json : { jobs: jobs.fetch(argv[3]) }.to_json
      [out, "", instance_double(Process::Status, success?: true)]
    end
  end

  def verdict = JSON.parse(reader.head(commit: sha, repo: repo).fetch(:text))

  it "answers green when every job of every run passed", :aggregate_failures do
    answer_gh(runs: [{ databaseId: 1, status: "completed", conclusion: "success", workflowName: "CI" }],
              jobs: { "1" => [{ name: "rspec", conclusion: "success" }, { name: "lint", conclusion: "skipped" }] })

    expect(verdict).to include("color" => "green", "failing_jobs" => "")
  end

  it "answers red and names each job that failed" do
    answer_gh(runs: [{ databaseId: 2, status: "completed", conclusion: "failure", workflowName: "CI" }],
              jobs: { "2" => [{ name: "rspec", conclusion: "failure" }, { name: "lint", conclusion: "success" }] })

    expect(verdict).to include("color" => "red", "failing_jobs" => "rspec")
  end

  it "refuses while a run for the commit is still going" do
    answer_gh(runs: [{ databaseId: 3, status: "in_progress", conclusion: "", workflowName: "CI" }])

    expect { reader.head(commit: sha, repo: repo) }.to raise_error(Hecks::Runtime::GivenNotMet, /still running/)
  end

  it "refuses a commit that CI never ran for" do
    answer_gh(runs: [])

    expect { reader.head(commit: sha, repo: repo) }.to raise_error(Hecks::Runtime::GivenNotMet, /no CI run/)
  end
end
