require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "hecks/tools"
require "hecks/tools/ci_gates"

# The path gates are `CiGate` rows of the Vocabulary chapter. `hecks project_ci_gates` writes each
# row into the marked region of its workflow, and the job it writes runs `hecks decide_ci_gate`, so
# CI asks the binary rather than carrying shell of its own. This spec holds the committed workflows
# to the rows; spec/tools_ci_gate_decision_spec.rb holds what the decision answers.
RSpec.describe Hecks::Tools::CiGates do
  let(:root) { Hecks::Tools::ROOT }

  describe "the committed workflows" do
    it "hold exactly what the CiGate rows project" do
      described_class.projection(root).each do |path, text|
        expect(File.read(path)).to eq(text),
                                   "#{path.delete_prefix("#{root}/")} has drifted from the CiGate rows — " \
                                   "run hecks project_ci_gates"
      end
    end

    # CI does not circumvent the binary: the step that decides is a call to `hecks`, and the only
    # local actions a detector job uses are the ones that set up Ruby and the journal.
    it "decide every gate by running the binary, with no shell of their own" do
      described_class.gates.each do |gate|
        workflow = YAML.load_file(File.join(root, ".github/workflows", gate.fetch("workflow")))
        steps = workflow.dig("jobs", gate.fetch("name"), "steps")
        decide = steps.find { |step| step["id"] == "diff" }

        expect(decide["run"]).to eq("bundle exec exe/hecks decide_ci_gate gate=#{gate.fetch('name')} --wait")
        local = steps.filter_map { |step| step["uses"] }.select { |uses| uses.start_with?("./") }
        expect(local).to eq(%w[./.github/actions/setup-ruby ./.github/actions/hecks-environment])
      end
    end

    it "gate stress_concurrency and the postgres_io shards on the detector jobs" do
      ci = YAML.load_file(File.join(root, ".github/workflows/ci.yml"))
      postgres = YAML.load_file(File.join(root, ".github/workflows/ci-postgres-io-parallel.yml"))

      expect(ci.dig("jobs", "stress_concurrency", "needs")).to eq("runtime_changed")
      expect(ci.dig("jobs", "runtime_changed", "if")).to eq("github.event_name != 'push'")
      expect(postgres.dig("jobs", "postgres_io_relevant_changed")).not_to have_key("if")
    end
  end

  describe "main" do
    let(:work) { Dir.mktmpdir("ci_gates_root") }

    before do
      FileUtils.mkdir_p(File.join(work, ".github/workflows"))
      described_class.gates.map { |gate| gate.fetch("workflow") }.uniq.each do |name|
        FileUtils.cp(File.join(root, ".github/workflows", name), File.join(work, ".github/workflows", name))
      end
    end

    after { FileUtils.rm_rf(work) }

    it "answers 0 when every region is current" do
      expect { expect(described_class.main(["--check"], root: work)).to eq(0) }.to output(/every region current/).to_stdout
    end

    it "names a workflow whose region was edited by hand, and writes nothing under --check" do
      path = File.join(work, ".github/workflows/ci.yml")
      edited = File.read(path).sub("timeout-minutes: 10\n    # A push", "timeout-minutes: 99\n    # A push")
      File.write(path, edited)

      expect { expect(described_class.main(["--check"], root: work)).to eq(1) }
        .to output(%r{out of date: \.github/workflows/ci\.yml}).to_stderr
      expect(File.read(path)).to eq(edited)
    end

    it "restores the region when it is not a check" do
      path = File.join(work, ".github/workflows/ci.yml")
      File.write(path, File.read(path).sub("timeout-minutes: 10\n    # A push", "timeout-minutes: 99\n    # A push"))

      expect { described_class.main([], root: work) }.to output(%r{wrote \.github/workflows/ci\.yml}).to_stdout
      expect(File.read(path)).to eq(described_class.projection(work).fetch(path))
    end

    it "refuses a workflow with no marked region for a gate" do
      path = File.join(work, ".github/workflows/ci.yml")
      File.write(path, File.read(path).gsub(/^  # (BEGIN|END) GENERATED ci_gate runtime_changed.*\n/, ""))

      expect { described_class.main([], root: work) }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
        .and output(%r{no BEGIN/END GENERATED ci_gate runtime_changed region}).to_stderr
    end
  end
end
