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

  def violations_for(text, rule) = self.class.lint(text).select { |violation| violation.rule == rule }

  # --- Fabricated recipes ------------------------------------------------

  LINT_EXIT_ZERO_BAD = <<~MAKEFILE.freeze
    mint-era:
    \t@aws cloudformation describe-stacks --stack-name $(STACK) >/dev/null; \\
    \texit 0
  MAKEFILE

  LINT_SHARED_STUB_FINE = <<~MAKEFILE.freeze
    mint-era:
    \t@echo "mint-era isn't automated yet for a Shared-mode domain -- this is NOT a failure"; \\
    \texit 0
  MAKEFILE

  LINT_GATED_EXIT_FINE = <<~MAKEFILE.freeze
    mint-era:
    \t@echo "Looking up stuff..."
    \taws cloudformation describe-stacks --stack-name $(STACK) >/dev/null && exit 0
  MAKEFILE

  LINT_STATUS_VARIABLE_FINE = <<~MAKEFILE.freeze
    mint-era:
    \t@echo "Looking up stuff..."
    \taws cloudformation describe-stacks --stack-name $(STACK)
    \tBOOT_STATUS=$$?; \\
    \texit $$BOOT_STATUS
  MAKEFILE

  LINT_STALE_BAD = <<~MAKEFILE.freeze
    stale-check:
    \t@aws cloudformation describe-stacks --stack-name $(STACK) >/dev/null; \\
    \techo "done"; \\
    \texit $$?
  MAKEFILE

  LINT_STALE_FINE = <<~MAKEFILE.freeze
    stale-check:
    \t@echo "Looking up stuff..."
    \taws cloudformation describe-stacks --stack-name $(STACK) >/dev/null; \\
    \texit $$?
  MAKEFILE

  LINT_TOUCH_BAD = <<~MAKEFILE.freeze
    touch-prod:
    \taws ssm start-session --target i-123
  MAKEFILE

  LINT_DATABASE_BAD = <<~MAKEFILE.freeze
    touch-db:
    \tcd $(ROOT) && DATABASE_URL="postgres://x" ruby -e 'puts 1'
  MAKEFILE

  LINT_ECHOED_FINE = <<~MAKEFILE.freeze
    touch-prod:
    \t@echo "About to look up the stack..."
    \taws ssm start-session --target i-123
  MAKEFILE

  # A comment can contain "aws cloudformation" or "echo" as prose; only an
  # executing shell statement may satisfy or trigger the check.
  LINT_COMMENT_PROSE_BAD = <<~MAKEFILE.freeze
    touch-prod:
    # this comment mentions aws cloudformation and echo in plain prose
    \taws ssm start-session --target i-123
  MAKEFILE

  LINT_SAM_BUILD_FINE = <<~MAKEFILE.freeze
    build-thing:
    \tsam build thing
  MAKEFILE

  # --- 1. Catches the bug class on fabricated recipes -------------------

  describe "UNVERIFIED_EXIT_ZERO — the H13 shape" do
    it "flags a target that runs an AWS/DB command, then unconditionally exits 0 without checking it", :aggregate_failures do
      exit_zero = violations_for(LINT_EXIT_ZERO_BAD, "UNVERIFIED_EXIT_ZERO")

      expect(exit_zero.size).to eq(1)
      expect(exit_zero.first.target).to eq("mint-era")
      expect(exit_zero.first.line).to eq(3)
      expect(exit_zero.first.message).to include("aws cloudformation")
    end

    it "does NOT flag exit 0 when nothing risky precedes it in the same chain (the real, fixed Shared-mode stub's own shape)" do
      expect(self.class.lint(LINT_SHARED_STUB_FINE)).to be_empty
    end

    it "does NOT flag `command && exit 0` — that exit IS genuinely gated on the command's own success" do
      expect(self.class.lint(LINT_GATED_EXIT_FINE)).to be_empty
    end

    it "does NOT flag a real command's status captured into a variable and exited by name (this codebase's own convention)" do
      expect(self.class.lint(LINT_STATUS_VARIABLE_FINE)).to be_empty
    end
  end

  describe "STALE_DOLLAR_QUESTION — exit $? not actually set by the meaningful command" do
    it "flags `exit $?` whose immediately preceding statement is a benign echo, not the risky command", :aggregate_failures do
      stale = violations_for(LINT_STALE_BAD, "STALE_DOLLAR_QUESTION")

      expect(stale.size).to eq(1)
      expect(stale.first.line).to eq(4)
      expect(stale.first.message).to include("echo")
    end

    it "does NOT flag `exit $?` immediately following the real risky command itself" do
      expect(self.class.lint(LINT_STALE_FINE)).to be_empty
    end
  end

  describe "PROD_TOUCH_WITHOUT_ECHO — the H14 shape, generalized" do
    it "flags a target that touches AWS/DB with no earlier echo/validation step at all", :aggregate_failures do
      touch = violations_for(LINT_TOUCH_BAD, "PROD_TOUCH_WITHOUT_ECHO")

      expect(touch.size).to eq(1)
      expect(touch.first.target).to eq("touch-prod")
      expect(touch.first.message).to include("aws ssm start-session")
    end

    it "flags a DATABASE_URL= connection with no preceding echo, same as an aws/psql call" do
      expect(self.class.lint(LINT_DATABASE_BAD).map(&:rule)).to include("PROD_TOUCH_WITHOUT_ECHO")
    end

    it "does NOT flag once ANY earlier real (non-comment) line in the recipe echoes something first" do
      expect(self.class.lint(LINT_ECHOED_FINE)).to be_empty
    end

    it "never counts a comment's own prose as either a risky touch or an echo (comments are invisible to a human running make)" do
      message = "a comment's own prose must not satisfy the echo requirement, nor itself count as the risky touch"

      expect(self.class.lint(LINT_COMMENT_PROSE_BAD).map(&:rule)).to eq(["PROD_TOUCH_WITHOUT_ECHO"]), message
    end

    it "ignores sam build (a local, non-AWS-touching step) as a risky trigger" do
      expect(self.class.lint(LINT_SAM_BUILD_FINE)).to be_empty
    end
  end

  # --- End-to-end CLI ----------------------------------------------------

  describe "the tool, in this process" do
    around do |example|
      Dir.mktmpdir do |dir|
        @dir = dir
        example.run
      end
    end

    def write_recipes
      clean = File.join(@dir, "clean")
      File.write(clean, "ok:\n\t@echo hi\n\taws cloudformation describe-stacks\n\tBOOT=$$?; \\\n\texit $$BOOT\n")
      bad = File.join(@dir, "bad")
      File.write(bad, "mint:\n\t@aws cloudformation describe-stacks >/dev/null; \\\n\texit 0\n")
      [clean, bad]
    end

    it "answers 0 for a clean Makefile, printing the report", :aggregate_failures do
      clean, = write_recipes

      expect { expect(Hecks::Tools::DeployRecipeLint.main([clean])).to eq(0) }.to output(/no violations found/).to_stdout
    end

    it "answers 1 for the H13 shape, printing the report", :aggregate_failures do
      _, bad = write_recipes

      expect { expect(Hecks::Tools::DeployRecipeLint.main([bad])).to eq(1) }.to output(/UNVERIFIED_EXIT_ZERO/).to_stderr
    end

    it "prints its usage for --help", :aggregate_failures do
      expect { expect(Hecks::Tools::DeployRecipeLint.main(["--help"])).to eq(0) }
        .to output(/usage: hecks deploy lint/).to_stdout
    end
  end

  LINT_CLEAN_TARGET = <<~MAKEFILE.freeze
    clean-target:
    \t@echo "about to look something up"
    \taws cloudformation describe-stacks --stack-name $(STACK)
    \tBOOT_STATUS=$$?; \\
    \texit $$BOOT_STATUS
  MAKEFILE

  describe "the CLI itself" do
    around do |example|
      Dir.mktmpdir do |dir|
        @dir = dir
        example.run
      end
    end

    # The child's whole program: the tool the launcher's `deploy lint` runs, as a process.
    def self.lint_command
      lib = File.join(root, "lib")
      [RbConfig.ruby, "-I", lib, "-e", 'require "hecks/tools"; Hecks::Tools.script("lint_deploy_recipes", ARGV)', "--"]
    end

    def self.run_lint(*args)
      Open3.capture3(*lint_command, *args, chdir: root)
    end

    # Writes `text` as a Makefile and runs the CLI on it, answering its stdout, stderr and status.
    def run_lint_on(text)
      path = File.join(@dir, "Makefile")
      File.write(path, text)
      self.class.run_lint(path)
    end

    it "exits 0 and prints 'no violations found' for a Makefile containing only clean targets", :aggregate_failures do
      stdout, _stderr, status = run_lint_on(LINT_CLEAN_TARGET)

      expect(status.success?).to be(true)
      expect(stdout).to include("no violations found")
    end

    it "exits nonzero and reports target/line/rule for a Makefile containing the H13 shape", :aggregate_failures do
      stdout, stderr, status = run_lint_on(LINT_EXIT_ZERO_BAD)

      expect(status.success?).to be(false)
      expect(stdout + stderr).to include("UNVERIFIED_EXIT_ZERO", "mint-era", ":3:")
    end

    describe "with no arguments" do
      # One real no-arguments run shared by both examples below.
      before(:context) do
        stdout, stderr, @no_args_status = self.class.run_lint
        @no_args_report = stdout + stderr
      end

      it "generates its own fixture domains and lints them (real `hecks deploy project` output)", :aggregate_failures do
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
