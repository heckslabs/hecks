require "hecks"
require_relative "../../lib/hecks/quality_control/adapters/github_checks"

# Transport only: `Open3.capture3` is stubbed so the suite never shells out to a real `gh`.
# The exact `gh api` argv and the green/red parsing run for real.
RSpec.describe Hecks::Adapters::GithubChecks do
  SHA = "4f2a19c8340fc53aa931933cb6587288698f51d".freeze

  def api_path(page = 1)
    "repos/{owner}/{repo}/commits/#{SHA}/check-runs?per_page=100&page=#{page}"
  end

  def stub_gh(stdout, success: true)
    status = instance_double(Process::Status, success?: success)
    allow(Open3).to receive(:capture3).with("gh", "api", api_path).and_return([stdout, "", status])
  end

  def check_run(name, status: "completed", conclusion: "success")
    { "name" => name, "status" => status, "conclusion" => conclusion }
  end

  def runs_json(*checks)
    JSON.generate({ "total_count" => checks.length, "check_runs" => checks })
  end

  subject(:adapter) { described_class.new }

  # `commit:` arrives as a materialized `{value: "…"}` hash (a Value never crosses the boundary);
  # the other two shapes are tolerated defensively.
  describe "commit shape" do
    it "reads a symbol-keyed materialized value object" do
      stub_gh(runs_json(check_run("rspec")))
      expect(adapter.run(commit: { value: SHA })).to eq(summary: { value: "1 checks, all green (4f2a19c)" })
    end

    it "reads a string-keyed hash" do
      stub_gh(runs_json(check_run("rspec")))
      expect(adapter.run(commit: { "value" => SHA })).to eq(summary: { value: "1 checks, all green (4f2a19c)" })
    end

    it "reads a bare string" do
      stub_gh(runs_json(check_run("rspec")))
      expect(adapter.run(commit: SHA)).to eq(summary: { value: "1 checks, all green (4f2a19c)" })
    end
  end

  describe "a clean run" do
    it "answers with how many checks and that they were all green" do
      stub_gh(runs_json(check_run("rspec"), check_run("rubocop"), check_run("fuzzing")))

      expect(adapter.run(commit: { value: SHA })).to eq(summary: { value: "3 checks, all green (4f2a19c)" })
    end

    # Neither success nor failure: GitHub's "ran, and chose not to fail the commit."
    it "does not count neutral or skipped runs against the commit" do
      stub_gh(runs_json(check_run("rspec"), check_run("path-filtered", conclusion: "skipped"),
                        check_run("advisory", conclusion: "neutral")))

      expect(adapter.run(commit: { value: SHA })[:summary][:value]).to include("3 checks, all green")
    end
  end

  describe "a red run" do
    it "raises naming exactly the checks that failed, and nothing else" do
      stub_gh(runs_json(check_run("rspec"), check_run("rubocop", conclusion: "failure"),
                        check_run("fuzzing", conclusion: "cancelled")))

      expect { adapter.run(commit: { value: SHA }) }
        .to raise_error(/2 of 3 checks failed against 4f2a19c: rubocop, fuzzing/)
    end
  end

  describe "nothing settled yet" do
    it "refuses when gh reports no checks at all" do
      stub_gh(runs_json)

      expect { adapter.run(commit: { value: SHA }) }
        .to raise_error(/no checks at all against #{SHA}/)
    end

    # Defensive: refuses rather than answering green if a check starts running mid-ask.
    it "refuses rather than answer green while a check is still running" do
      stub_gh(runs_json(check_run("rspec"), check_run("fuzzing", status: "in_progress", conclusion: nil)))

      expect { adapter.run(commit: { value: SHA }) }
        .to raise_error(/still running — asked before they settled/)
    end
  end

  describe "gh itself failing" do
    it "raises when the gh call does not succeed" do
      status = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture3)
        .with("gh", "api", api_path)
        .and_return(["", "gh: no such commit", status])

      expect { adapter.run(commit: { value: SHA }) }
        .to raise_error(/gh api check-runs failed for #{SHA}: gh: no such commit/)
    end

    it "raises a clear error when gh is not installed" do
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)

      expect { adapter.run(commit: { value: SHA }) }.to raise_error(RuntimeError, /gh is not installed/)
    end
  end

  describe "pagination" do
    it "reads every page so a red run past the first 100 is caught" do
      status = instance_double(Process::Status, success?: true)
      page1 = runs_json(*(0...100).map { |i| check_run("ok#{i}") })
      page2 = runs_json(check_run("late-red", conclusion: "failure"))
      allow(Open3).to receive(:capture3).with("gh", "api", api_path(1)).and_return([page1, "", status])
      allow(Open3).to receive(:capture3).with("gh", "api", api_path(2)).and_return([page2, "", status])

      expect { adapter.run(commit: { value: SHA }) }.to raise_error(/1 of 101 checks failed.*late-red/)
    end
  end

  describe "sha validation" do
    it "refuses a value that is not a sha before it reaches the API path" do
      expect(Open3).not_to receive(:capture3)

      expect { adapter.run(commit: { value: "abc/../../user" }) }.to raise_error(/not a commit sha/)
    end
  end

  # `answers "SuitePassed"`/`refuses "SuiteFailed"` spread this method's return or raise into
  # `Clearance::Passed`/`Failed`; the end-to-end flow is covered in spec/quality_control_spec.rb.
end
