require "tmpdir"
require "open3"
require "rbconfig"

require "hecks/tools/deploy_recipe_lint"

# Proves `hecks deploy lint` (Hecks::Tools::DeployRecipeLint) catches the H13/H14 bug class
# (docs/audits/2026-08-11-bug-triage.md) on fabricated recipes, and finds zero
# violations across every target of the generated own/shared/oauth Makefiles.
RSpec.describe "hecks deploy lint", :io do
  def self.root = File.expand_path("..", __dir__)

  def self.lint(text, source: "fixture")
    Hecks::Tools::DeployRecipeLint.lint(text, source: source)
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
      # A comment can contain "aws cloudformation" or "echo" as prose; only an
      # executing shell statement may satisfy or trigger the check.
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

  # --- End-to-end CLI ----------------------------------------------------

  describe "the tool, in this process" do
    it "answers 0 for a clean Makefile and 1 for the H13 shape, printing the report" do
      Dir.mktmpdir do |dir|
        clean = File.join(dir, "clean")
        File.write(clean, "ok:\n\t@echo hi\n\taws cloudformation describe-stacks\n\tBOOT=$$?; \\\n\texit $$BOOT\n")
        bad = File.join(dir, "bad")
        File.write(bad, "mint:\n\t@aws cloudformation describe-stacks >/dev/null; \\\n\texit 0\n")

        expect { expect(Hecks::Tools::DeployRecipeLint.main([clean])).to eq(0) }
          .to output(/no violations found/).to_stdout
        expect { expect(Hecks::Tools::DeployRecipeLint.main([bad])).to eq(1) }
          .to output(/UNVERIFIED_EXIT_ZERO/).to_stderr
      end
    end

    it "prints its usage for --help" do
      expect { expect(Hecks::Tools::DeployRecipeLint.main(["--help"])).to eq(0) }
        .to output(/usage: .*lint_deploy_recipes/).to_stdout
    end
  end

  describe "the CLI itself" do
    # The child's whole program: the tool the launcher's `deploy lint` runs, as a process.
    def self.lint_command
      lib = File.join(root, "lib")
      [RbConfig.ruby, "-I", lib, "-e", 'require "hecks/tools"; Hecks::Tools.script("lint_deploy_recipes", ARGV)', "--"]
    end

    def self.run_lint(*args)
      Open3.capture3(*lint_command, *args, chdir: root)
    end

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

        stdout, _stderr, status = self.class.run_lint(path)
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

        stdout, stderr, status = self.class.run_lint(path)
        expect(status.success?).to be(false)
        report = stdout + stderr
        expect(report).to include("UNVERIFIED_EXIT_ZERO")
        expect(report).to include("mint-era")
        expect(report).to include(":3:")
      end
    end

    describe "with no arguments" do
      # One real no-arguments run shared by both examples below.
      before(:context) do
        stdout, stderr, @no_args_status = self.class.run_lint
        @no_args_report = stdout + stderr
      end

      it "generates its own fixture domains and lints them (real `hecks deploy project` output)" do
        # A clean run is expected; a violation here is a regression in
        # the generated recipes of `hecks deploy project`.
        expect(@no_args_status.success?).to be(true), @no_args_report
        expect(@no_args_report).to include("no violations found")
      end

      it "cleans up every fixture domain it generates under deploy/, win or lose" do
        # Checks only the `lint_deploy_recipes_fixture_` prefix: deploy/ is shared scratch
        # space, and parallel workers create unrelated fixtures there mid-example.
        leftover = Dir.children(File.join(self.class.root, "deploy")).grep(/\Alint_deploy_recipes_fixture_/)

        expect(leftover).to be_empty,
                            "the recipe lint must not leave its own generated fixture domains behind " \
                            "under deploy/ after it finishes -- found: #{leftover.inspect}"
      end
    end
  end
end
