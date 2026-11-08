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

  # Every command of ci-checks.yml's run steps, one for each leg of a job's matrix, with the
  # leg's value written in where the command names it.
  def run_commands
    workflow.fetch("jobs").values.flat_map do |job|
      commands = job.fetch("steps", []).filter_map { |step| step["run"]&.strip }
      commands.flat_map { |command| legs_of(job, command) }
    end
  end

  def legs_of(job, command)
    job.dig("strategy", "matrix").to_h.reduce([command]) do |texts, (key, values)|
      texts.flat_map { |text| values.map { |value| text.gsub("${{ matrix.#{key} }}", value.to_s) } }
    end
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
      expect(push_drift.fetch("run")).to include("regeneration_run.regenerate_corpus!", "--check")
    end

    it "sets no env of its own, so a job's journal choice reaches its checks" do
      expect(stages.dig("ci", "env")).to be_empty
    end
  end

  describe "ci-checks.yml" do
    let(:launched) do
      run_commands.map do |command|
        match = command.match(%r{\Abundle exec exe/hecks gate_run\.gate! stage=ci only=([a-z0-9_,]+) --wait\z})
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

  describe "the push path" do
    def ids(stage) = stages.dig(stage, "checks").map { |check| check["id"] }

    it "runs in the push the seconds-long checks and no others" do
      expect(ids("quick")).to eq(%w[shape_ledger rubocop comment_style comment_blocks secret_output adapter_words io_spec_list])
    end

    it "has no unguarded_push stage, so the hook and a rehearsal run the quick stage alone" do
      expect(stages).not_to include("unguarded_push")
    end

    it "runs the hook's default push as the quick stage and nothing else", :aggregate_failures do
      hook = File.read(File.join(InMemoryDomain::ROOT, ".githooks/pre-push"))

      expect(hook).to include("' quick; then")
      expect(hook).not_to include("only=fuzzing")
    end

    it "gives every check a stage, and every check moved out of the push to CI", :aggregate_failures do
      listed = stages.values.flat_map { |stage| stage.fetch("checks") }.map { |check| check["id"] }
      rows = Hecks::Vocabulary.rows("GateCheck").map { |row| row["id"] }

      expect(rows - listed).to be_empty
      expect(ids("ci")).to include("command_names", "workflow_pagination")
      expect(ids("quick") & ids("ci")).to include("shape_ledger", "rubocop", "comment_style", "comment_blocks")
    end
  end

  # The [kind, verb] of each launcher call in a command line; model_check is a legacy word.
  def hecks_calls(command)
    command.scan(%r{exe/hecks ((?:ask |query |deploy )?)([a-z_.]+)}).map { |kind, verb| [kind.strip, verb] }
           .reject { |_, verb| verb == "model_check" }
  end

  describe "every hecks command a stage's check names" do
    def launcher_calls
      checks = stages.values_at("ci", "quick", "rust_io").flat_map { |stage| stage.fetch("checks") }
      checks.flat_map { |check| hecks_calls(check.fetch("run").join(" ")) }.uniq
    end

    def resolves?(hecks, kind, verb)
      _, status = Hecks::Adapters::Driving::CliRunner.call(runtime: hecks, argv: [kind, verb, "--help"].reject(&:empty?),
                                                           program: "hecks")
      status.zero?
    end

    it "resolves through the launcher", :aggregate_failures do
      calls = launcher_calls
      hecks = boot_hecks_in_memory
      unresolved = calls.reject { |kind, verb| resolves?(hecks, kind, verb) }

      expect(calls).not_to be_empty
      expect(unresolved).to be_empty, "hecks commands that do not resolve: #{unresolved.map { |call| call.join(" ").strip }}"
    end
  end
end
