require "spec_helper"
require "yaml"
require "hecks/tools"

# The `ci` stage of the Vocabulary gate rows is the one copy of what the CI workflow runs. These
# specs hold the workflow to the stage, so a command cannot be copied into it again, and a check
# cannot be left unrun.
RSpec.describe "the ci gate stage" do
  let(:root) { File.expand_path("..", __dir__) }
  let(:stages) { Hecks::Tools.fetch("gate").stages }
  let(:workflow) { YAML.load_file(File.join(root, ".github/workflows/ci-checks.yml")) }
  let(:ci_ids) { stages.dig("ci", "checks").map { |check| check["id"] } }

  # Every step of ci-checks.yml that runs something, with its command.
  def run_steps
    workflow.fetch("jobs").values.flat_map { |job| job.fetch("steps", []) }.select { |step| step["run"] }
  end

  describe "the ci stage" do
    it "names no check twice" do
      expect(ci_ids).to eq(ci_ids.uniq)
    end

    it "takes the checks pre_push shares from pre_push, not from a copy" do
      shared = stages.dig("ci", "checks").select { |check| stages.dig("pre_push", "checks").include?(check) }

      expect(shared.map { |check| check["id"] }).to include(
        "model_check", "engine_agreement", "doc_coverage", "rubocop", "comment_style", "comment_blocks"
      )
    end

    it "compares codegen drift against the job's own regeneration rather than regenerating again", :aggregate_failures do
      ci_drift = stages.dig("ci", "checks").find { |check| check["id"] == "codegen_drift" }
      push_drift = stages.dig("pre_push", "checks").find { |check| check["id"] == "codegen_drift" }

      expect(ci_drift.fetch("run")).to start_with("git", "diff", "--exit-code")
      expect(ci_drift.fetch("run")).to include("rust/src/generated", "rust/Cargo.toml")
      expect(push_drift.fetch("run")).to include("regeneration_run.regenerate_corpus", "--check")
    end

    it "sets no env of its own, so a job's journal choice reaches its checks" do
      expect(stages.dig("ci", "env")).to be_empty
    end
  end

  describe "ci-checks.yml" do
    let(:launched) do
      run_steps.map { |step| step["run"].strip }.map do |command|
        match = command.match(%r{\Abundle exec exe/hecks gate_run\.gate stage=ci only=([a-z_,]+) --wait\z})
        [command, match && match[1].split(",")]
      end
    end

    it "runs nothing but a ci-stage gate, so no command is copied into it" do
      launched.each do |command, ids|
        expect(ids).not_to be_nil, "ci-checks.yml runs `#{command}`; move it into the ci stage of the Vocabulary gate rows"
      end
    end

    it "runs only checks the stage holds, and every check of the stage exactly once", :aggregate_failures do
      ids = launched.flat_map(&:last)

      expect(ids - ci_ids).to be_empty
      expect(ids.sort).to eq(ci_ids.sort), "ci stage checks run by no step, or by several: " \
                                           "#{((ids - ci_ids) + (ci_ids - ids) + ids.select { |id| ids.count(id) > 1 }).uniq}"
    end
  end

  describe "the unguarded_push stage" do
    it "holds the fuzzing check pre_push holds, since no commit hook runs it" do
      fuzzing = stages.dig("pre_push", "checks").select { |check| check["id"] == "fuzzing" }

      expect(stages.dig("unguarded_push", "checks")).to include(*fuzzing)
    end
  end

  describe "the quick stage" do
    def ids(stage) = stages.dig(stage, "checks").map { |check| check["id"] }

    it "is the unguarded_push checks other than fuzzing, so fuzzing is the only work it saves" do
      expect(ids("quick")).to eq(ids("unguarded_push") - ["fuzzing"])
    end

    it "runs before fuzzing in the hook, which stops on a red quick check" do
      hook = File.read(File.join(InMemoryDomain::ROOT, ".githooks/pre-push"))

      expect(hook).to match(/' quick \|\|\s+! .* unguarded_push only=fuzzing/)
    end
  end

  # The [kind, verb] of each launcher call in a command line; model_check is a legacy word.
  def hecks_calls(command)
    command.scan(%r{exe/hecks ((?:ask |query |deploy )?)([a-z_.]+)}).map { |kind, verb| [kind.strip, verb] }
           .reject { |_, verb| verb == "model_check" }
  end

  describe "every hecks command a stage's check names" do
    def launcher_calls
      checks = stages.values_at("ci", "unguarded_push", "quick", "rust_io").flat_map { |stage| stage.fetch("checks") }
      checks.flat_map { |check| hecks_calls(check.fetch("run").join(" ")) }.uniq
    end

    def resolves?(hecks, kind, verb)
      _, status = Hecks::Adapters::Driving::CliRunner.call(runtime: hecks, argv: [kind, verb, "--help"].reject(&:empty?),
                                                           program: "hecks")
      status.zero?
    end

    it "resolves through the launcher", :aggregate_failures do
      calls = launcher_calls
      hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false)
      unresolved = calls.reject { |kind, verb| resolves?(hecks, kind, verb) }

      expect(calls).not_to be_empty
      expect(unresolved).to be_empty, "hecks commands that do not resolve: #{unresolved.map { |call| call.join(" ").strip }}"
    end
  end
end
