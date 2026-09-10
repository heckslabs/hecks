require "hecks"
require_relative "../../qa/adapters/github_checks"

# TRANSPORT ONLY — never spawns the real `gh` binary (that would make this
# suite hit live GitHub on every run: slow, rate-limited, non-deterministic,
# and the one thing `spec/quality_control_spec.rb`'s own `GreenCi`/`RedCi`
# stubs exist specifically to avoid needing at the port-and-policy level).
# `Open3.capture3` is stubbed at the boundary; everything upstream of it
# (the exact `gh api` argv, how a response is parsed into green or red) runs
# for real — the same split `claude_code_spec.rb` already uses for its own
# shelled-out adapter.
RSpec.describe Hecks::Adapters::GithubChecks do
  SHA = "4f2a19c8340fc53aa931933cb6587288698f51d".freeze

  def stub_gh(stdout, success: true)
    status = instance_double(Process::Status, success?: success)
    allow(Open3).to receive(:capture3)
      .with("gh", "api", "repos/{owner}/{repo}/commits/#{SHA}/check-runs")
      .and_return([stdout, "", status])
  end

  def check_run(name, status: "completed", conclusion: "success")
    { "name" => name, "status" => status, "conclusion" => conclusion }
  end

  def runs_json(*checks)
    JSON.generate({ "total_count" => checks.length, "check_runs" => checks })
  end

  subject(:adapter) { described_class.new }

  # `commit:` ARRIVES AS THE VALUE OBJECT'S OWN MATERIALIZED SHAPE — a
  # `{value: "…"}` hash, per `PortOperationInterpreter#ask`'s own comment
  # ("a Value never crosses the boundary"). This is the one shape a live
  # dispatch actually hands the adapter (see `quality_control.hecksagon`'s
  # own port declaration), exercised end to end elsewhere; the other two
  # shapes below are tolerated defensively, not load-bearing for the port.
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

    # A CONCLUSION THAT ISN'T `success` BUT ISN'T A FAILURE EITHER —
    # GitHub's own words for "ran, and chose not to fail the commit."
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

    # DEFENSIVE, NOT EXPECTED — `bin/qa_pr_check` only ever asks once its
    # own `gh pr checks` has already shown nothing pending. This is the
    # adapter's own guard against the rare race where a check starts
    # running in between (see this class's own header comment on why it
    # refuses rather than silently answering green).
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
        .with("gh", "api", "repos/{owner}/{repo}/commits/#{SHA}/check-runs")
        .and_return(["", "gh: no such commit", status])

      expect { adapter.run(commit: { value: SHA }) }
        .to raise_error(/gh api check-runs failed for #{SHA}: gh: no such commit/)
    end
  end

  # THE PORT'S OWN CONTRACT — `answers "SuitePassed"`/`refuses "SuiteFailed"`
  # (`quality_control.hecksagon`) reach `Clearance::Passed`/`Failed` by
  # spreading whatever this method returns/raises straight into the
  # triggered command's own arguments (`PortOperationInterpreter#ask`'s own
  # comment: "spread, not nested"). `Clearance::Passed` declares `summary`;
  # `Clearance::Failed` declares `refusal`, filled from this raise's own
  # message. Both are exercised end to end (a real boot, a real dispatch,
  # the real `ClearOnPass`/`RefuseOnFail` policies actually firing) in
  # `spec/quality_control_spec.rb`'s own "clearance" and "the CI watch"
  # examples — this file stays scoped to what THIS class alone decides.
end
