require "hecks"
require_relative "../../lib/hecks/quality_control/adapters/github_checks"

# Transport only: `Open3.capture3` is stubbed, so the suite never shells out to a real `gh`.
RSpec.describe Hecks::Adapters::GithubChecks, "#states" do
  subject(:adapter) { described_class.new }

  let(:sha) { "4f2a19c8340fc53aa931933cb6587288698f51d" }
  let(:path) { "repos/{owner}/{repo}/commits/#{sha}/check-runs?per_page=100&page=1" }

  def stub_gh(*runs)
    status = instance_double(Process::Status, success?: true)
    body = JSON.generate({ "total_count" => runs.length, "check_runs" => runs })
    allow(Open3).to receive(:capture3).with("gh", "api", path).and_return([body, "", status])
  end

  def run(name, id: 1, status: "completed", conclusion: "success")
    { "name" => name, "id" => id, "status" => status, "conclusion" => conclusion }
  end

  it "tells a passed check from a failed one, a running one and one that never reported" do
    stub_gh(run("rspec"), run("checks", conclusion: "failure"), run("rspec_rust_io", status: "in_progress", conclusion: nil))

    expect(adapter.states(commit: { value: sha }, names: %w[rspec checks rspec_rust_io rspec_fuzzing])).to eq(
      "rspec" => :passed, "checks" => :failed, "rspec_rust_io" => :pending, "rspec_fuzzing" => :missing
    )
  end

  it "counts a skipped check as passed, as a path-filtered job reports" do
    stub_gh(run("rspec_postgres_io_parallel", conclusion: "skipped"))

    expect(adapter.states(commit: sha, names: ["rspec_postgres_io_parallel"])).to eq("rspec_postgres_io_parallel" => :passed)
  end

  it "takes the most recent report of a check that was run again" do
    stub_gh(run("rspec", id: 1, conclusion: "failure"), run("rspec", id: 2, conclusion: "success"))

    expect(adapter.states(commit: sha, names: ["rspec"])).to eq("rspec" => :passed)
  end

  it "refuses a malformed sha before asking GitHub", :aggregate_failures do
    allow(Open3).to receive(:capture3)

    expect { adapter.states(commit: "main; rm -rf /", names: ["rspec"]) }.to raise_error(/not a commit sha/)
    expect(Open3).not_to have_received(:capture3)
  end
end
