require "tmpdir"
require "fileutils"
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
#   2. It does not cry wolf on the targets bin/project_deploy generates
#      TODAY for the recipes those fixes actually touched (mint-era,
#      scaffold-translation, translation-audit, migrate-console-settings,
#      rename-schema, sync-google-oauth all pass with zero violations).
#
# `deploy:` USED TO be excluded from the "known clean" set below — running
# this linter against the real generator used to surface one genuine (if
# low-severity) finding there: PROD_TOUCH_WITHOUT_ECHO on
# predeploy_bridge_shell's own `aws cloudformation describe-stacks`
# existence check (and, in Shared mode, the owner-stack Outputs lookup),
# both of which used to run with no echo of their own before them (only
# prose comments, invisible to a human running `make deploy`, explained
# them). Now fixed — bin/project_deploy echoes what each of those AWS
# calls is about to check, right before making it — so `deploy` is folded
# into KNOWN_CLEAN_TARGETS below like every other target, and the CLI's
# own "no arguments" test now expects a clean run. If this ever regresses
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

  # --- 2. Runs clean against the REAL generator's fixed targets ---------

  describe "against bin/project_deploy's real, current generated output" do
    def self.write_fixture(dir, basename, world_body, env_local: nil)
      domain_dir = File.join(dir, basename)
      bluebook_dir = File.join(domain_dir, "bluebook")
      FileUtils.mkdir_p(bluebook_dir)
      bluebook_name = basename.split("_").map(&:capitalize).join

      File.write(File.join(bluebook_dir, "#{basename}.bluebook"), <<~BLUEBOOK)
        Hecks.bluebook "#{bluebook_name}" do
          aggregate "Thing" do
            identified_by :name
            attribute :name, ThingName
            value_object "ThingName" do
              attribute :value, String
              invariant("named") { !value.to_s.empty? }
            end
            command "Create" do
              attribute :name, ThingName
              sets :name
              emits "ThingCreated"
            end
          end
        end
      BLUEBOOK

      File.write(File.join(bluebook_dir, "#{basename}.world"), <<~WORLD)
        Hecks.world "#{bluebook_name}" do
          deployed_to("AwsLambda") do
            #{world_body}
          end
        end
      WORLD

      File.write(File.join(domain_dir, ".env.local"), env_local) if env_local
      domain_dir
    end

    def self.generate!(basename, world_body, env_local: nil)
      Dir.mktmpdir do |dir|
        domain_dir = write_fixture(dir, basename, world_body, env_local: env_local)
        _stdout, stderr, status = Open3.capture3("ruby", File.join(root, "bin/project_deploy"), domain_dir)
        status.success? or raise "bin/project_deploy failed: #{stderr}"
      end
      File.join(root, "deploy", basename)
    end

    before(:context) do
      @own_dir = self.class.generate!("lint_spec_own_fixture", <<~WORLD)
        region "us-east-1"
      WORLD
      @shared_dir = self.class.generate!("lint_spec_shared_fixture", <<~WORLD)
        region "us-east-1"
        database "Shared"
        owner "SomeOwner"
      WORLD
      env_local = %(GOOGLE_CLIENT_ID=test-client-id.apps.googleusercontent.com\nGOOGLE_CLIENT_SECRET=test-secret\n)
      @oauth_dir = self.class.generate!("lint_spec_oauth_fixture", <<~WORLD, env_local: env_local)
        region "us-east-1"
        web "Rust"
      WORLD
    end

    after(:context) do
      FileUtils.rm_rf(@own_dir)
      FileUtils.rm_rf(@shared_dir)
      FileUtils.rm_rf(@oauth_dir)
    end

    # The exact targets H13/H14/L20 fixed: mint-era (Shared-mode stub,
    # H13), scaffold-translation/translation-audit (the ALLOW_LOCAL_DB
    # REFUSING guard, H14), rename-schema (identifier validation, L20).
    # migrate-console-settings and sync-google-oauth are generated the
    # same way and belong in the same "known clean" set. `deploy` joined
    # this set once predeploy_bridge_shell's own `describe-stacks` check
    # (and, in Shared mode, the owner-stack Outputs lookup) gained an
    # echo of their own — see this file's own top comment.
    KNOWN_CLEAN_TARGETS = %w[mint-era scaffold-translation translation-audit migrate-console-settings rename-schema
                             sync-google-oauth deploy].freeze

    it "finds zero violations in mint-era/scaffold-translation/translation-audit/migrate-console-settings/rename-schema " \
       "for an own-RDS domain" do
      makefile = File.read(File.join(@own_dir, "Makefile"))
      violations = self.class.lint(makefile, source: "own").select { |v| KNOWN_CLEAN_TARGETS.include?(v.target) }
      expect(violations).to be_empty, violations.join("\n")
    end

    it "finds zero violations in the same targets for a Shared-mode domain (H13/H14's own Shared-mode branches)" do
      makefile = File.read(File.join(@shared_dir, "Makefile"))
      violations = self.class.lint(makefile, source: "shared").select { |v| KNOWN_CLEAN_TARGETS.include?(v.target) }
      expect(violations).to be_empty, violations.join("\n")
    end

    it "finds zero violations in the same targets (plus sync-google-oauth) for an OAuth-present domain" do
      makefile = File.read(File.join(@oauth_dir, "Makefile"))
      violations = self.class.lint(makefile, source: "oauth").select { |v| KNOWN_CLEAN_TARGETS.include?(v.target) }
      expect(violations).to be_empty, violations.join("\n")
    end

    it "finds zero violations on deploy: itself now that predeploy_bridge_shell's describe-stacks check echoes first" do
      # Used to be a pinned, known PROD_TOUCH_WITHOUT_ECHO finding here —
      # see this file's own top comment. Now fixed; pinned the other way
      # so a regression (the echo silently disappearing again) is caught.
      %w[own shared oauth].each do |label|
        dir = instance_variable_get(:"@#{label}_dir")
        makefile = File.read(File.join(dir, "Makefile"))
        deploy_violations = self.class.lint(makefile, source: label).select { |v| v.target == "deploy" }
        expect(deploy_violations).to be_empty, deploy_violations.join("\n")
      end
    end
  end

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

    it "with no arguments, generates its own fixture domains and lints them (real bin/project_deploy output)" do
      stdout, stderr, status = Open3.capture3("ruby", self.class.script)
      report = stdout + stderr

      # Used to pin one known, real, reported-not-fixed PROD_TOUCH_WITHOUT_
      # ECHO finding on `deploy` here — see this file's own top comment.
      # Now fixed, so a genuinely clean run is expected; ANY violation
      # reappearing here is a regression in bin/project_deploy's own
      # generated recipes.
      expect(status.success?).to be(true)
      expect(report).to include("no violations found")
    end

    it "cleans up every fixture domain it generates under deploy/, win or lose" do
      before_entries = Dir.children(File.join(self.class.root, "deploy")).sort
      Open3.capture3("ruby", self.class.script)
      after_entries = Dir.children(File.join(self.class.root, "deploy")).sort

      expect(after_entries).to eq(before_entries),
                               "bin/lint_deploy_recipes must not leave its own generated fixture domains behind " \
                               "under deploy/ after it finishes"
    end
  end
end
