require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/vocabulary"
require "hecks/hecks/adapters/codebase/source_tree"
require "hecks/hecks/adapters/git_rehearsal"
require "hecks/hecks/adapters/settings_reading"
require "hecks/hecks/adapters/dispatching/brief_text"

# Owner decision, locked down in the bluebook: the full spec suite runs only in CI. Locally a change
# is checked by the quick gate and by named specs, at most the world's `spec_files_limit` per call.
# The runner is stubbed, so no spec file is run.
RSpec.describe "the full spec suite runs only in CI", :aggregate_failures do
  let(:registry) { Hecks.describe(domain_dir).registry }
  let(:folder) { Dir.mktmpdir("ci-only-suite") }

  def domain_dir = File.join(InMemoryDomain::ROOT, "lib/hecks/hecks")

  def limit = 25

  # The repo's world sets no cap, so the capping examples declare one; `:no_cap` leaves it unset.
  def declare_cap
    world = registry.world("Hecks")
    allow(world).to receive(:for_verb).and_call_original
    allow(world).to receive(:for_verb).with("test_scope").and_wrap_original do |original, *args|
      original.call(*args).merge(spec_files_limit: limit)
    end
  end

  def failure = Hecks::Adapters::ConsoleCapture::Failure

  def codebase = Hecks::Adapters::Codebase

  def rows(name) = Hecks::Vocabulary.rows(name)

  def stage_names(scope) = Hecks::Adapters::GitRehearsal::Stages.rows(scope).map { |row| row["name"] }

  def perform(operation, **held)
    Hecks::Adapters::SourceTree.new(registry: registry)
                               .perform(operation: { value: operation }, root: { value: folder }, **held)
  end

  def refusal(operation, **held)
    perform(operation, **held)
    nil
  rescue failure => e
    e.message
  end

  def spec_files(count)
    Array.new(count) { |index| File.join(folder, "n#{index}_spec.rb").tap { |path| File.write(path, "") } }
         .map { |path| File.basename(path) }.join(" ")
  end

  around do |example|
    kept = %w[CI GITHUB_ACTIONS].to_h { |name| [name, ENV.delete(name)] }
    example.run
  ensure
    kept.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
    FileUtils.rm_rf(folder)
  end

  before do |example|
    runner = instance_double(codebase::TestRunner, run_paths: "1 example, 0 failures", outcome: [0, "1 example, 0 failures"])
    allow(codebase::TestRunner).to receive(:new).and_return(runner)
    declare_cap unless example.metadata[:no_cap]
  end

  describe "the rows" do
    it "declares the rspec check as a CI-only check, listed by the ci_suite stage alone" do
      check = rows("GateCheck").find { |row| row["name"] == "rspec" }
      listing = rows("GateStage").select { |row| row["checks"].split(",").include?("rspec") }

      expect(check["runs_in"]).to eq("ci")
      expect(listing.map { |row| row["name"] }).to eq(["ci_suite"])
    end

    it "gives quick the gate's quick stage alone, and deep the impacted stage as well" do
      expect(stage_names("quick")).to eq(%w[quick])
      expect(stage_names("deep")).to eq(%w[quick impacted])
    end

    it "points the gate stages at GateStage rows" do
      gates = Hecks::Adapters::GitRehearsal::Stages.rows("deep").select { |row| row["kind"] == "gate" }

      expect(gates.map { |row| row["argument"] }).to all(satisfy { |name| rows("GateStage").any? { |s| s["name"] == name } })
    end

    it "asks for a quick rehearsal after a land" do
      policy = registry.bluebook("Hecks").policies.find { |found| found.name == "RehearseWhenLanded" }

      expect(policy.instance_variable_get(:@with_spec)[:scope]).to eq({ value: "quick" })
    end
  end

  describe "the setting" do
    it "is shown by config, with its source" do
      text = Hecks::Adapters::SettingsReading.new.settings(domain: { value: domain_dir })[:text]

      expect(text).to include("test scope: full suite in ci; at most #{limit} spec files per call locally (world)")
    end

    it "is declared by the Hecks world" do
      expect(registry.world("Hecks").for_verb("test_scope")).to include(suite_runs_in: "ci")
    end
  end

  describe "run_suite!" do
    it "is refused by name outside CI" do
      expect(refusal("run_suite")).to eq(
        "the full suite runs in CI (rspec runs_in \"ci\"); run named specs, or run_impacted_specs!"
      )
    end

    it "is allowed in CI" do
      ENV["CI"] = "true"

      expect(refusal("run_suite")).to be_nil
    end

    it "is allowed in GitHub Actions" do
      ENV["GITHUB_ACTIONS"] = "true"

      expect(refusal("run_suite")).to be_nil
    end
  end

  describe "run_spec_files!" do
    it "runs any number of spec files when the world sets no limit", :no_cap do
      expect(refusal("run_spec_files", files: { value: spec_files(limit + 5) })).to be_nil
    end

    it "runs a call at the limit" do
      expect(refusal("run_spec_files", files: { value: spec_files(limit) })).to be_nil
    end

    it "refuses a call over the limit, naming the limit and CI" do
      message = refusal("run_spec_files", files: { value: spec_files(limit + 1) })

      expect(message).to start_with("run_spec_files! runs at most #{limit} spec files per call locally (spec_files_limit)")
      expect(message).to include("#{limit + 1} named", "The full suite runs in CI")
    end

    it "counts a directory as the spec files it holds" do
      FileUtils.mkdir_p(File.join(folder, "family"))
      (limit + 1).times { |index| File.write(File.join(folder, "family", "n#{index}_spec.rb"), "") }

      expect(refusal("run_spec_files", files: { value: "family" })).to include("#{limit + 1} named")
    end

    it "runs more than the limit in CI" do
      ENV["CI"] = "true"

      expect(refusal("run_spec_files", files: { value: spec_files(limit + 1) })).to be_nil
    end
  end

  describe "run_impacted_specs!" do
    it "refuses a cap over the limit locally" do
      expect(refusal("run_impacted_specs", cap: { value: limit + 1 })).to include("caps at #{limit} spec files locally")
    end

    it "caps a run that names none at the limit" do
      impacted = instance_double(codebase::ImpactedSpecs, call: "mapped")
      allow(codebase::ImpactedSpecs).to receive(:new).and_return(impacted)

      perform("run_impacted_specs")

      expect(impacted).to have_received(:call).with(hash_including(cap: limit))
    end
  end

  describe "the brief" do
    it "fills the limit in from the setting" do
      brief = { "verification" => { "value" => "at most {limit} spec files per call locally" } }
      text = Hecks::Adapters::Dispatching::BriefText.new(brief).render("w", limit: limit)

      expect(text).to include("at most #{limit} spec files per call locally")
    end

    it "has no number of its own in the Coder bluebook" do
      source = File.read(File.join(InMemoryDomain::ROOT, "lib/hecks/coder/coder.bluebook"))

      expect(source).to include("Run at most {limit} spec files per call locally")
    end
  end
end
