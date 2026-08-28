require "tmpdir"
require "fileutils"
require "open3"

# Phase 8 (equivalence-gap plan) — "make parity a build gate, not a test
# claim." `bin/project_deploy` used to have zero hook into any Ruby/Rust
# conformance check at all: parity was proven only against CI's fixed
# test corpus, completely decoupled from what a real `sam deploy` was
# about to ship. `bin/project_deploy`'s own generated `deploy:` target
# now runs `bin/rust_conformance` against the SPECIFIC compiled artifact
# ($(WASM)) `build-<LogicalId>` (the same target) just built — not a
# corpus-wide `cargo build`'s own separate binary — before `sam deploy`
# ever runs. See the generator's own "make verify-parity-<LogicalId>"
# comment (bin/project_deploy) for the full design.
#
# Two halves, matching the plan's own verification requirement ("confirm
# the new deploy-time gate actually blocks a deliberately-broken
# artifact... before trusting it in production") — a STRUCTURAL check
# that the generated Makefile actually wires the new target into
# `deploy:`, and a FUNCTIONAL one, proving the underlying mechanism
# (`bin/rust_conformance`'s own exit code) genuinely fails on a real
# mismatch and passes on a real match, not just that the right words
# appear in generated text.
RSpec.describe "the per-deploy Ruby/Rust parity gate (Phase 8)", io: true do
  def self.repo_root = File.expand_path("..", __dir__)

  # --- Structural: the generated Makefile actually wires it in ---------

  describe "the generated Makefile" do
    PARITY_GATE_FIXTURE_BASENAME = "parity_gate_spec_fixture"

    before(:context) do
      Dir.mktmpdir do |dir|
        domain_dir = File.join(dir, PARITY_GATE_FIXTURE_BASENAME)
        bluebook_dir = File.join(domain_dir, "bluebook")
        FileUtils.mkdir_p(bluebook_dir)

        File.write(File.join(bluebook_dir, "#{PARITY_GATE_FIXTURE_BASENAME}.bluebook"), <<~BLUEBOOK)
          Hecks.bluebook "#{PARITY_GATE_FIXTURE_BASENAME.split('_').map(&:capitalize).join}" do
            aggregate "Widget" do
              identified_by :id
              attribute :id, Id

              value_object "Id" do
                attribute :value, String
              end

              command "Create" do
                emits "WidgetCreated"
              end
            end
          end
        BLUEBOOK

        File.write(File.join(bluebook_dir, "#{PARITY_GATE_FIXTURE_BASENAME}.world"), <<~WORLD)
          Hecks.world "#{PARITY_GATE_FIXTURE_BASENAME.split('_').map(&:capitalize).join}" do
            region "us-east-1"
            deployed_to("AwsLambda") do
              region "us-east-1"
            end
          end
        WORLD

        _stdout, stderr, status = Open3.capture3("ruby", File.join(self.class.repo_root, "bin/project_deploy"), domain_dir)
        status.success? or raise "bin/project_deploy failed: #{stderr}"
      end
      @generated_dir = File.join(self.class.repo_root, "deploy", PARITY_GATE_FIXTURE_BASENAME)
      @makefile = File.read(File.join(@generated_dir, "Makefile"))
    end

    after(:context) { FileUtils.rm_rf(@generated_dir) }

    it "declares a verify-parity-<LogicalId> target" do
      expect(@makefile).to match(/^\.PHONY: verify-parity-\w+$/)
      expect(@makefile).to match(/^verify-parity-\w+:$/)
    end

    it "runs bin/rust_conformance against $(WASM) — the exact artifact build-<LogicalId> just produced" do
      target_body = @makefile[/^verify-parity-\w+:\n(?:\t.*\n?)+/]
      expect(target_body).to include("bin/rust_conformance")
      expect(target_body).to include("$(WASM)")
    end

    it "calls verify-parity-<LogicalId> from deploy:'s own recipe, before sam deploy would run" do
      deploy_body = @makefile[/^deploy:\n(?:\t.*\n?)+/]
      expect(deploy_body).to match(/\$\(MAKE\) verify-parity-\w+/)
    end

    it "warns loudly, rather than silently skipping, when this domain has no spec/corpus/<name>.json fixture yet" do
      # This fixture domain has no spec/corpus/parity_gate_spec_fixture.json —
      # exactly the "no fixture to compare against" case a domain with a
      # real corpus script (banking, pizzas, roster, compliance) never
      # hits. Structural proof the fallback path exists and is not a
      # quiet no-op: the generated recipe names the exact reason and
      # exactly what's missing.
      target_body = @makefile[/^verify-parity-\w+:\n(?:\t.*\n?)+/]
      expect(target_body).to include("SKIPPING")
      expect(target_body).to include("spec/corpus/#{PARITY_GATE_FIXTURE_BASENAME}.json")
    end
  end

  # --- Functional: the underlying mechanism actually catches a real ------
  # --- mismatch, and actually passes on a real match --------------------

  describe "bin/rust_conformance itself, against real compiled artifacts (the exact command the Makefile target runs)" do
    def self.wasm_for(domain_path)
      domain_name = File.basename(domain_path)
      _stdout, stderr, status = Open3.capture3("ruby", "bin/project_wasm", domain_path, chdir: repo_root)
      status.success? or raise "bin/project_wasm #{domain_path} failed: #{stderr}"
      File.join(repo_root, "rust", "dist", "#{domain_name}.wasm")
    end

    # `bin/project_wasm` regenerates `rust/src/generated/` (that domain's
    # own tree, plus any shared framework chapter it depends on) and
    # rewrites `rust/Cargo.toml`'s own `default` feature as a SIDE
    # EFFECT of building the .wasm this spec actually needs — the same
    # behavior `bin/project_rust`'s own regen has throughout this whole
    # plan's own commit history. Restoring exactly the files THIS run
    # newly dirtied (`after` minus `before`, never the WHOLE post-run
    # diff — a session with its own already-uncommitted work in progress
    # would otherwise have THAT work silently reverted the moment this
    # spec's own `after(:context)` fires, exactly the mistake this
    # comment exists to name so it never gets repeated) is what keeps
    # this spec from leaving the working tree — and every OTHER spec
    # that reads `rust/src/generated/`'s current committed content —
    # dirty after a single run, WITHOUT ever touching a file this run
    # didn't itself modify.
    def self.tracked_diff
      `git -C #{repo_root} diff --name-only`.split("\n")
    end

    def self.restore_tracked_diff(paths)
      return if paths.empty?

      system("git", "-C", repo_root, "checkout", "--", *paths)
    end

    before(:context) do
      @dirty_before_this_spec = self.class.tracked_diff
      @roster_wasm = self.class.wasm_for("examples/roster")
      @pizzas_wasm = self.class.wasm_for("examples/pizzas")
    end

    after(:context) do
      newly_dirtied = self.class.tracked_diff - @dirty_before_this_spec
      self.class.restore_tracked_diff(newly_dirtied)
    end

    def rust_conformance(domain, script, artifact)
      Open3.capture3("bin/rust_conformance", domain, script, artifact, chdir: self.class.repo_root)
    end

    # `spec/corpus/rust_conformance/roster.json`, not the fuzzer's own
    # broader `spec/corpus/roster.json` — the FORMER is one of the
    # fixtures `spec/rust_conformance_spec.rb` already proves matches
    # byte-for-byte; the LATTER is known, live, and cited (ADR 0037,
    # Finding 3) to hit the missing-argument wording gap that spec's own
    # documented, not-yet-fixed catalogue leaves open — using it here
    # would make this spec re-litigate an already-catalogued gap instead
    # of proving what THIS phase's own mechanism does.
    ROSTER_FIXTURE = "spec/corpus/rust_conformance/roster.json"

    it "passes (exit 0) when the artifact and the domain genuinely agree" do
      _stdout, _stderr, status = rust_conformance("examples/roster", ROSTER_FIXTURE, @roster_wasm)
      expect(status).to be_success
    end

    # THE PLAN'S OWN EXPLICIT VERIFICATION REQUIREMENT: "confirm the new
    # deploy-time gate actually blocks a deliberately-broken artifact."
    # The most reliable way to inject one without hand-authoring a
    # broken .wasm: feed the harness a WILDLY MISMATCHED pairing — a
    # real domain's own corpus script against a DIFFERENT domain's real,
    # correctly-built artifact. Every one of Ruby's own event/refusal
    # names comes from roster's own vocabulary; pizzas' compiled dispatch
    # table has never heard of any of them, so the comparison is
    # guaranteed to diverge (never a silent, accidental match this
    # deliberately-broken case might have real corpus overlap with).
    it "fails (non-zero exit) when the artifact is a genuinely different, deliberately-mismatched compiled domain" do
      stdout, stderr, status = rust_conformance("examples/roster", ROSTER_FIXTURE, @pizzas_wasm)
      expect(status).not_to be_success
      expect(stdout + stderr).to include("mismatch")
    end
  end
end
