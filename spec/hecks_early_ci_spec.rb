require "spec_helper"
require_relative "support/fake_branch_ci"

# Early CI: a landed branch is recorded for an early run under ci/<branch>, the switch turns it off,
# main is never started, and a CI result is kept on the record. The domain is in Memory.
RSpec.describe "early CI" do
  describe "record" do
    before(:all) do
      @hecks = boot_hecks_in_memory
    end

    def launch(*argv)
      outer = Thread.current[:hecks_reaction_depth]
      Thread.current[:hecks_reaction_depth] = 0
      Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")
    ensure
      Thread.current[:hecks_reaction_depth] = outer
    end

    def start(run, branch, *extra)
      out, = launch("EarlyCi.start!", "run.value=#{run}", "branch.value=#{branch}", *extra, "--wait")
      out.to_s
    end

    it "records a landed coder branch", :aggregate_failures do
      out = start("ec-1", "coder-x")
      expect(out).to include("EarlyCiStarted")
      expect(out).to include("requested")
    end

    it "refuses main" do
      expect(start("ec-2", "main")).not_to include("EarlyCiStarted")
    end

    it "refuses to start when the switch is off" do
      expect(start("ec-3", "coder-y", "early_ci.value=false")).not_to include("EarlyCiStarted")
    end

    it "keeps what CI said of the branch" do
      start("ec-4", "coder-z")
      launch("EarlyCi.open!", "to=ec-4", "number.value=12", "--wait")
      out, = launch("EarlyCi.observe!", "to=ec-4", "outcome.value=passed", "report.value=ok",
                    "of_sha.value=abcdef1234", "--wait")
      expect(out.to_s).to include("EarlyCiObserved")
    end
  end

  # A coder's request before hand-off: the port pushes ci/<branch>, reuses or opens the draft
  # and reads the run of the head; the verdict is drawn from the failed jobs, and a late answer
  # for an earlier head is refused. GitHub and git are a fake runner.
  describe "before hand-off" do
    before(:all) do
      @hecks = boot_hecks_in_memory
    end

    before do
      Hecks::Adapters::GithubBranchCi.runner = FakeBranchCi.new
      Hecks::Adapters::GithubBranchCi.pause = ->(_seconds) {}
    end

    after do
      Hecks::Adapters::GithubBranchCi.runner = nil
      Hecks::Adapters::GithubBranchCi.pause = nil
    end

    def launch(*argv)
      outer = Thread.current[:hecks_reaction_depth]
      Thread.current[:hecks_reaction_depth] = 0
      out, = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")
      out.to_s
    ensure
      Thread.current[:hecks_reaction_depth] = outer
    end

    def request(branch, sha = "abcdef1234", clean: true)
      launch("EarlyCi.request!", "run.value=#{branch}", "branch.value=#{branch}", "sha.value=#{sha}",
             "checkout.value=/tmp", "clean.value=#{clean}", "--wait")
    end

    def fake = Hecks::Adapters::GithubBranchCi.runner

    def red(name) = [{ "id" => 2, "name" => name, "conclusion" => "failure" }]

    def retried(branch, sha)
      launch("EarlyCi.retry!", "to=#{branch}", "sha.value=#{sha}", "clean.value=true", "--wait")
    end

    # Requests a branch whose run is queued once, and observes it at another head while it waits.
    def late_answer(branch)
      fake.running = 1
      late = nil
      Hecks::Adapters::GithubBranchCi.pause = lambda do |_seconds|
        late ||= launch("EarlyCi.observe!", "to=#{branch}", "outcome.value=passed", "report.value=old",
                        "of_sha.value=0000000000", "--wait")
      end
      request(branch)
      late
    end

    it "pushes the head as ci/<branch> and records a green run", :aggregate_failures do
      out = request("coder-green")
      expect(out).to include("EarlyCiObserved", "passed")
      expect(fake.calls).to include(["git", "push", "origin", "abcdef1234:refs/heads/ci/coder-green"])
    end

    it "records a run with a failed job as failed, naming the job" do
      fake.jobs = red("rspec_io")
      expect(request("coder-red")).to include("failed", "rspec_io")
    end

    it "refuses main, stable, a train and ci/ branches", :aggregate_failures do
      %w[main stable train/main-abc ci/x].each { |branch| expect(request(branch)).not_to include("EarlyCiRequested") }
    end

    it "refuses a tree that is not clean" do
      expect(request("coder-dirty", clean: false)).not_to include("EarlyCiRequested")
    end

    it "retries a red branch at its new head" do
      fake.jobs = red("rspec_io")
      request("coder-fix")
      fake.jobs = []
      expect(retried("coder-fix", "bbbbbbb222")).to include("passed", "bbbbbbb222")
    end

    it "declines a run that has not ended in the wait, naming it" do
      fake.running = 1000
      expect(request("coder-slow")).to include("EarlyCiDeclined")
    end

    it "refuses an answer for another head while a request is in flight" do
      expect(late_answer("coder-late")).to include("CI answered for the record's own head")
    end
  end
end
