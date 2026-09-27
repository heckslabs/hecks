require "tmpdir"
require "fileutils"
require "open3"

# The generated `deploy:` target runs bin/rust_conformance against the built $(WASM) before
# `sam deploy`. Checks the Makefile wiring and that the conformance exit code is real.
RSpec.describe "the per-deploy Ruby/Rust parity gate (Phase 8)", :io do
  def self.repo_root = File.expand_path("..", __dir__)

  describe "the generated Makefile" do
    PARITY_GATE_FIXTURE_BASENAME = "parity_gate_spec_fixture".freeze

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
      # This fixture has no spec/corpus/parity_gate_spec_fixture.json, so the recipe
      # must name what is missing rather than no-op.
      target_body = @makefile[/^verify-parity-\w+:\n(?:\t.*\n?)+/]
      expect(target_body).to include("SKIPPING")
      expect(target_body).to include("spec/corpus/#{PARITY_GATE_FIXTURE_BASENAME}.json")
    end
  end

  describe "bin/rust_conformance itself, against real compiled artifacts (the exact command the Makefile target runs)" do
    def self.wasm_for(domain_path)
      domain_name = File.basename(domain_path)
      _stdout, stderr, status = Open3.capture3("ruby", "bin/project_wasm", domain_path, chdir: repo_root)
      status.success? or raise "bin/project_wasm #{domain_path} failed: #{stderr}"
      File.join(repo_root, "rust", "dist", "#{domain_name}.wasm")
    end

    # bin/project_wasm builds in a scratch copy of the crate; this snapshots the real
    # crate paths (tracked and untracked) to prove they stay untouched.
    def self.crate_status
      `git -C #{repo_root} status --porcelain -- rust/Cargo.toml rust/src`.split("\n")
    end

    before(:context) do
      @crate_status_before = self.class.crate_status
      @roster_wasm = self.class.wasm_for("examples/roster")
      @pizzas_wasm = self.class.wasm_for("examples/pizzas")
    end

    it "leaves rust/Cargo.toml and rust/src/generated untouched" do
      expect(self.class.crate_status).to eq(@crate_status_before)
    end

    def rust_conformance(domain, script, artifact)
      Open3.capture3("bin/rust_conformance", domain, script, artifact, chdir: self.class.repo_root)
    end

    # Not the fuzzer's broader spec/corpus/roster.json, which hits a known
    # missing-argument wording gap (ADR 0037).
    ROSTER_FIXTURE = "spec/corpus/rust_conformance/roster.json".freeze

    it "passes (exit 0) when the artifact and the domain genuinely agree" do
      _stdout, _stderr, status = rust_conformance("examples/roster", ROSTER_FIXTURE, @roster_wasm)
      expect(status).to be_success
    end

    # Pairs roster's corpus with pizzas' artifact, whose dispatch table knows none of
    # roster's event names, so the comparison must diverge.
    it "fails (non-zero exit) when the artifact is a genuinely different, deliberately-mismatched compiled domain" do
      stdout, stderr, status = rust_conformance("examples/roster", ROSTER_FIXTURE, @pizzas_wasm)
      expect(status).not_to be_success
      expect(stdout + stderr).to include("mismatch")
    end
  end
end
