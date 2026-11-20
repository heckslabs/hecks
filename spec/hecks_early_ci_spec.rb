require "spec_helper"
require_relative "support/fake_branch_ci"

# Early CI: a landed branch is recorded and its ci/<branch> draft closed, the switch turns it off,
# main is never started, and a coder's request keeps what CI said. The domain is in Memory; GitHub
# and git are a fake runner.
RSpec.describe "early CI" do
  describe "record" do
    before(:all) do
      @hecks = boot_hecks_in_memory
    end

    before { Hecks::Adapters::GithubBranchCi.runner = FakeBranchCi.new }

    after { Hecks::Adapters::GithubBranchCi.runner = nil }

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

    it "records a landed coder branch and closes its draft" do
      expect(start("ec-1", "coder-x")).to include("EarlyCiStarted", "EarlyCiClosed", "closed draft #7")
    end

    it "refuses main" do
      expect(start("ec-2", "main")).not_to include("EarlyCiStarted")
    end

    it "refuses to start when the switch is off" do
      expect(start("ec-3", "coder-y", "early_ci.value=false")).not_to include("EarlyCiStarted")
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

    def request(branch, sha = "abcdef1234", clean: true, run: branch)
      launch("EarlyCi.request!", "run.value=#{run}", "branch.value=#{branch}", "sha.value=#{sha}",
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

    it "replaces ci/<branch> after a rebase: the second request is accepted and observed", :aggregate_failures do
      request("coder-rebased", "aaaaaaa111")
      expect(request("coder-rebased", "bbbbbbb222", run: "coder-rebased-2"))
        .to include("EarlyCiRequested", "EarlyCiObserved", "passed")
      expect(fake.calls).to include(["git", "push", "--force-with-lease=refs/heads/ci/coder-rebased:aaaaaaa111",
                                     "origin", "bbbbbbb222:refs/heads/ci/coder-rebased"])
    end

    it "pushes plainly when no ci/<branch> exists" do
      request("coder-first")
      expect(fake.calls.select { |argv| argv[0, 2] == %w[git push] })
        .to eq([["git", "push", "origin", "abcdef1234:refs/heads/ci/coder-first"]])
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

    # A landed branch's draft is closed and ci/<branch> deleted through the port, never merged. The
    # landing runs in a process of its own, where no coder asked CI for the branch: the record the
    # landing starts is the one withdrawn. A branch still open keeps its draft.
    describe "when the branch lands" do
      # Reacts to `Landing.BranchLanded` for the branch as the event pump would, with the one policy
      # that starts its early CI record; a Landing cannot be made here without the git port.
      def land(branch)
        event = Hecks::Runtime::Event.new(name: "BranchLanded", aggregate: "Delivery::Landing", id: "land-#{branch}",
                                          payload: { run: { value: "land-#{branch}" }, branch: { value: branch } },
                                          occurred_at: Hecks::Runtime::Event.stamp)
        interpreter.react(event, "Delivery", only: [start, "Hecks"]).first
      end

      def interpreter
        Hecks::Runtime::PolicyInterpreter.new(@hecks.registry, dispatcher: Hecks::Runtime::Dispatcher.new(@hecks.registry))
      end

      def start
        @hecks.registry.bluebook("Hecks").policies.find { |policy| policy.name == "StartEarlyCiWhenBranchLanded" }
      end

      # The payload of the last `name` event recorded for the branch, empty when none was.
      def recorded(name, branch)
        found = @hecks.registry.event_log.reverse.find { |event| event.name == name && event.payload.to_s.include?(branch) }
        found ? found.payload.to_s : ""
      end

      def closes = fake.calls.select { |argv| argv.include?("PATCH") || argv.include?("DELETE") }

      CLOSES = [%w[gh api --method PATCH -f state=closed repos/{owner}/{repo}/pulls/7],
                %w[gh api --method DELETE repos/{owner}/{repo}/git/refs/heads/ci/coder-lands]].freeze

      it "closes the draft of a branch no coder asked CI for here and deletes ci/<branch>", :aggregate_failures do
        land("coder-lands")
        expect(closes).to eq(CLOSES)
        expect(fake.calls.map { |argv| argv.join(" ") }.grep(%r{pr merge|/merge\b})).to be_empty
        expect(recorded("EarlyCiClosed", "ci/coder-lands")).to include("closed draft #7")
      end

      it "closes nothing when main lands" do
        land("main")
        expect(closes).to be_empty
      end

      it "keeps the draft of a branch that has not landed", :aggregate_failures do
        request("coder-open")
        expect(closes).to be_empty
        expect(recorded("EarlyCiWithdrawn", "coder-open")).to be_empty
      end

      it "closes again with nothing open, as the first close did" do
        fake.drafts = []
        fake.ref_gone = true
        expect(Hecks::Adapters::GithubBranchCi.new.branch_ci_close(branch: "coder-gone", checkout: "/tmp"))
          .to eq(number: "", report: "no open draft for ci/coder-gone; no branch ci/coder-gone")
      end
    end

    # A job that failed on the run of the branch's base, on the same examples, is inherited: it is
    # reported apart and does not stop the hand-off. A failure of the branch's own still does.
    describe "on a red main" do
      def failed(id, name, *examples)
        fake.logs[id] = examples.map { |example| "#{name}\tRun rspec\t2026Z rspec #{example} # fails" }.join("\n")
        { "id" => id, "name" => name, "conclusion" => "failure" }
      end

      def red_main
        fake.base_jobs = [failed(12, "rspec_1", "./spec/stale_spec.rb:4"), failed(13, "lint")]
      end

      it "passes a branch whose only failures failed on its base, naming them inherited", :aggregate_failures do
        red_main
        fake.jobs = [failed(2, "rspec_2", "./spec/stale_spec.rb:4")]
        out = request("coder-inherits")
        expect(out).to include("passed", "own failures: none")
        expect(out).to include("inherited from main (run 50", "rspec_2 [./spec/stale_spec.rb:4]")
      end

      it "fails a branch with a failure of its own, listing the inherited one apart", :aggregate_failures do
        red_main
        fake.jobs = [failed(2, "rspec_2", "./spec/stale_spec.rb:4"), failed(3, "rspec_3", "./spec/new_spec.rb:9")]
        out = request("coder-own")
        expect(out).to include("failed", "own failures:\\nrspec_3: [./spec/new_spec.rb:9] ")
        expect(out).to include("inherited from main", "rspec_2 [./spec/stale_spec.rb:4]")
      end

      it "keeps a job that names no example the branch's own, though its base failed one of that name" do
        red_main
        fake.jobs = [failed(4, "lint")]
        expect(request("coder-lint")).to include("failed", "own failures:\\nlint: ")
      end

      it "keeps every failure the branch's own when its base has no ended run" do
        fake.jobs = [failed(2, "rspec_2", "./spec/stale_spec.rb:4")]
        expect(request("coder-unread")).to include("failed", "every failure is the branch's own")
      end
    end
  end
end
