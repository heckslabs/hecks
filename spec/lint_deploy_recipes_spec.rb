require "tmpdir"
require "open3"

# bin/lint_deploy_recipes is a SCRIPT, not a library (bin/stores_spec.rb's
# own header explains the convention this repo already follows for a bin/
# tool with nothing to require) — its CLI runs only when invoked as the
# main program (`if $PROGRAM_NAME == __FILE__`), so `Kernel.load`'ing it
# here (not `require`, which doesn't resolve an extension-less path — see
# this file's own header comment history) defines DeployRecipeLint without
# ever running that CLI block, letting the checks below be driven directly
# against hand-built Makefile text as well as through the real CLI.
Kernel.load(File.expand_path("../bin/lint_deploy_recipes", __dir__))

# Proves two things about bin/lint_deploy_recipes:
#
#   1. It actually catches the BUG CLASS behind H13/H14 (docs/audits/
#      2026-08-11-bug-triage.md) — a fabricated recipe reproducing each
#      shape gets flagged, not just the two now-fixed real instances.
#   2. It does not cry wolf on what bin/project_deploy generates TODAY —
#      the CLI's own no-arguments run lints every target of its three
#      real generated fixture Makefiles (own/shared/oauth) and must find
#      zero violations, including the recipes those fixes actually
#      touched (mint-era, scaffold-translation, translation-audit,
#      migrate-console-settings, rename-schema, sync-google-oauth).
#
# `deploy:` USED TO be excluded from the "known clean" set below — running
# this linter against the real generator used to surface one genuine (if
# low-severity) finding there: PROD_TOUCH_WITHOUT_ECHO on
# predeploy_bridge_shell's own `aws cloudformation describe-stacks`
# existence check (and, in Shared mode, the owner-stack Outputs lookup),
# both of which used to run with no echo of their own before them (only
# prose comments, invisible to a human running `make deploy`, explained
# them). Now fixed — bin/project_deploy echoes what each of those AWS
# calls is about to check, right before making it — so the CLI's own
# "no arguments" test now expects a clean run across every target,
# `deploy` included. If this ever regresses
# (the echo silently gets lost again), these assertions will fail.
RSpec.describe "bin/lint_deploy_recipes", :io do
  def self.root = File.expand_path("..", __dir__)

  def self.lint(text, source: "fixture")
    DeployRecipeLint.lint(text, source: source)
  end

  # --- 1. Catches the bug class on fabricated recipes -------------------

  describe "UNVERIFIED_EXIT_ZERO — the H13 shape" do
    it "flags a target that runs an AWS/DB command, then unconditionally exits 0 without checking it" do
      bad = <<~MAKEFILE
        mint-era:
        \t@aws cloudformation describe-stacks --stack-name $(STACK) >/dev/null; \\
        \texit 0
      MAKEFILE

      violations = self.class.lint(bad)

      exit_zero = violations.select { |v| v.rule == "UNVERIFIED_EXIT_ZERO" }
      expect(exit_zero.size).to eq(1)
      expect(exit_zero.first.target).to eq("mint-era")
      expect(exit_zero.first.line).to eq(3)
      expect(exit_zero.first.message).to include("aws cloudformation")
    end

    it "does NOT flag exit 0 when nothing risky precedes it in the same chain (the real, fixed Shared-mode stub's own shape)" do
      fine = <<~MAKEFILE
        mint-era:
        \t@echo "mint-era isn't automated yet for a Shared-mode domain -- this is NOT a failure"; \\
        \texit 0
      MAKEFILE

      expect(self.class.lint(fine)).to be_empty
    end

    it "does NOT flag `command && exit 0` — that exit IS genuinely gated on the command's own success" do
      fine = <<~MAKEFILE
        mint-era:
        \t@echo "Looking up stuff..."
        \taws cloudformation describe-stacks --stack-name $(STACK) >/dev/null && exit 0
      MAKEFILE

      expect(self.class.lint(fine)).to be_empty
    end

    it "does NOT flag a real command's status captured into a variable and exited by name (this codebase's own convention)" do
      fine = <<~MAKEFILE
        mint-era:
        \t@echo "Looking up stuff..."
        \taws cloudformation describe-stacks --stack-name $(STACK)
        \tBOOT_STATUS=$$?; \\
        \texit $$BOOT_STATUS
      MAKEFILE

      expect(self.class.lint(fine)).to be_empty
    end
  end

  describe "STALE_DOLLAR_QUESTION — exit $? not actually set by the meaningful command" do
    it "flags `exit $?` whose immediately preceding statement is a benign echo, not the risky command" do
      bad = <<~MAKEFILE
        stale-check:
        \t@aws cloudformation describe-stacks --stack-name $(STACK) >/dev/null; \\
        \techo "done"; \\
        \texit $$?
      MAKEFILE

      violations = self.class.lint(bad)
      stale = violations.select { |v| v.rule == "STALE_DOLLAR_QUESTION" }
      expect(stale.size).to eq(1)
      expect(stale.first.line).to eq(4)
      expect(stale.first.message).to include("echo")
    end

    it "does NOT flag `exit $?` immediately following the real risky command itself" do
      fine = <<~MAKEFILE
        stale-check:
        \t@echo "Looking up stuff..."
        \taws cloudformation describe-stacks --stack-name $(STACK) >/dev/null; \\
        \texit $$?
      MAKEFILE

      expect(self.class.lint(fine)).to be_empty
    end
  end

  describe "PROD_TOUCH_WITHOUT_ECHO — the H14 shape, generalized" do
    it "flags a target that touches AWS/DB with no earlier echo/validation step at all" do
      bad = <<~MAKEFILE
        touch-prod:
        \taws ssm start-session --target i-123
      MAKEFILE

      violations = self.class.lint(bad)
      touch = violations.select { |v| v.rule == "PROD_TOUCH_WITHOUT_ECHO" }
      expect(touch.size).to eq(1)
      expect(touch.first.target).to eq("touch-prod")
      expect(touch.first.message).to include("aws ssm start-session")
    end

    it "flags a DATABASE_URL= connection with no preceding echo, same as an aws/psql call" do
      bad = <<~MAKEFILE
        touch-db:
        \tcd $(ROOT) && DATABASE_URL="postgres://x" ruby -e 'puts 1'
      MAKEFILE

      expect(self.class.lint(bad).map(&:rule)).to include("PROD_TOUCH_WITHOUT_ECHO")
    end

    it "does NOT flag once ANY earlier real (non-comment) line in the recipe echoes something first" do
      fine = <<~MAKEFILE
        touch-prod:
        \t@echo "About to look up the stack..."
        \taws ssm start-session --target i-123
      MAKEFILE

      expect(self.class.lint(fine)).to be_empty
    end

    it "never counts a comment's own prose as either a risky touch or an echo (comments are invisible to a human running make)" do
      # A comment can innocently contain the word "aws cloudformation" or
      # "echo" in its own explanation — confirmed live in the real
      # generator's own predeploy_bridge_shell comment, which literally
      # contains the substring "sam deploy" as prose. Neither should ever
      # satisfy (or trigger) this check; only a REAL, executing shell
      # statement counts.
      bad = <<~MAKEFILE
        touch-prod:
        # this comment mentions aws cloudformation and echo in plain prose
        \taws ssm start-session --target i-123
      MAKEFILE

      violations = self.class.lint(bad)
      expect(violations.map(&:rule)).to eq(["PROD_TOUCH_WITHOUT_ECHO"]),
                                        "a comment's own prose must not satisfy the echo requirement, nor itself " \
                                        "count as the risky touch"
    end

    it "ignores sam build (a local, non-AWS-touching step) as a risky trigger" do
      fine = <<~MAKEFILE
        build-thing:
        \tsam build thing
      MAKEFILE

      expect(self.class.lint(fine)).to be_empty
    end
  end

  # --- 2. End-to-end CLI — including the REAL generator's output ---------
  #
  # The no-arguments example below is what proves (2) above: it
  # generates the same own/shared/oauth fixture domains
  # (`DeployRecipeLint.fixtures`) through the real bin/project_deploy
  # and requires ZERO violations across EVERY target in each generated
  # Makefile — a strict superset of the per-target "known clean" checks
  # this file used to run against its own separately-generated copies of
  # those same three fixtures.
  #
  # --- End-to-end CLI ----------------------------------------------------

  describe "the CLI itself" do
    def self.script = File.join(root, "bin/lint_deploy_recipes")

    it "exits 0 and prints 'no violations found' for a Makefile containing only clean targets" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "Makefile")
        File.write(path, <<~MAKEFILE)
          clean-target:
          \t@echo "about to look something up"
          \taws cloudformation describe-stacks --stack-name $(STACK)
          \tBOOT_STATUS=$$?; \\
          \texit $$BOOT_STATUS
        MAKEFILE

        stdout, _stderr, status = Open3.capture3("ruby", self.class.script, path)
        expect(status.success?).to be(true)
        expect(stdout).to include("no violations found")
      end
    end

    it "exits nonzero and reports target/line/rule for a Makefile containing the H13 shape" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "Makefile")
        File.write(path, <<~MAKEFILE)
          mint-era:
          \t@aws cloudformation describe-stacks --stack-name $(STACK) >/dev/null; \\
          \texit 0
        MAKEFILE

        stdout, stderr, status = Open3.capture3("ruby", self.class.script, path)
        expect(status.success?).to be(false)
        report = stdout + stderr
        expect(report).to include("UNVERIFIED_EXIT_ZERO")
        expect(report).to include("mint-era")
        expect(report).to include(":3:")
      end
    end

    describe "with no arguments" do
      # ONE real no-arguments run (three real bin/project_deploy builds)
      # shared by both examples below — the cleanup check needs a
      # finished run, not a second one of its own.
      before(:context) do
        stdout, stderr, @no_args_status = Open3.capture3("ruby", self.class.script)
        @no_args_report = stdout + stderr
      end

      it "generates its own fixture domains and lints them (real bin/project_deploy output)" do
        # Used to pin one known, real, reported-not-fixed PROD_TOUCH_WITHOUT_
        # ECHO finding on `deploy` here — see this file's own top comment.
        # Now fixed, so a genuinely clean run is expected; ANY violation
        # reappearing here is a regression in bin/project_deploy's own
        # generated recipes.
        expect(@no_args_status.success?).to be(true), @no_args_report
        expect(@no_args_report).to include("no violations found")
      end

      it "cleans up every fixture domain it generates under deploy/, win or lose" do
        # NAMED, not "the whole listing is unchanged" — that first version
        # of this check found a real bug in ITSELF, not in
        # bin/lint_deploy_recipes: deploy/ is shared, unscoped scratch
        # space, and other spec files (spec/project_deploy_bug_fixes_spec.rb's
        # own "h14_own_fixture", for one) generate their own fixtures
        # there too. Confirmed live — a before/after directory-listing
        # diff caught "added: [\"h14_own_fixture\"]" that had nothing to
        # do with this example: a DIFFERENT spec file's own
        # before(:context), running concurrently in a different
        # parallel_rspec worker, created it in the same shared directory
        # during this example's own before/after window. What this
        # example can actually verify is narrower and immune to that:
        # bin/lint_deploy_recipes always namespaces its own fixtures
        # "lint_deploy_recipes_fixture_<label>" (its own CLI body, above)
        # — checking that prefix specifically, rather than the directory's
        # full contents, is what a concurrent sibling's own unrelated
        # entries can no longer make flaky. Checked after the shared
        # before(:context) run above has fully finished, win or lose.
        leftover = Dir.children(File.join(self.class.root, "deploy")).grep(/\Alint_deploy_recipes_fixture_/)

        expect(leftover).to be_empty,
                            "bin/lint_deploy_recipes must not leave its own generated fixture domains behind " \
                            "under deploy/ after it finishes -- found: #{leftover.inspect}"
      end
    end
  end
end
