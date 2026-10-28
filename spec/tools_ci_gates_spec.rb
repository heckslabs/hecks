require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "hecks/tools"
require "hecks/tools/ci_gates"

# The path gates are `CiGate` rows of the Vocabulary bluebook.
# `hecks regeneration_run.project_ci_gates` writes each row into the marked region of its
# workflow, and the job it writes runs `hecks regeneration_run.decide_ci_gate`, so CI asks the
# binary rather than carrying shell of its own. This spec holds the committed workflows to the
# rows; spec/tools_ci_gate_decision_spec.rb holds what the decision answers.
RSpec.describe Hecks::Tools::CiGates do
  let(:root) { Hecks::Tools::ROOT }

  describe "the committed workflows" do
    it "hold exactly what the CiGate rows project" do
      described_class.projection(root).each do |path, text|
        expect(File.read(path)).to eq(text),
                                   "#{path.delete_prefix("#{root}/")} has drifted from the CiGate rows — " \
                                   "run hecks regeneration_run.project_ci_gates"
      end
    end

    # CI does not circumvent the binary: the step that decides is a call to `hecks`, and the only
    # local actions a detector job uses are the ones that set up Ruby, restore the boot caches
    # and choose the journal.
    def workflow_steps(gate)
      YAML.load_file(File.join(root, ".github/workflows", gate.fetch("workflow"))).dig("jobs", gate.fetch("name"), "steps")
    end

    it "decide every gate by running the binary" do
      described_class.gates.each do |gate|
        decide = workflow_steps(gate).find { |step| step["id"] == "diff" }

        expect(decide["run"]).to eq("bundle exec exe/hecks regeneration_run.decide_ci_gate gate=#{gate.fetch("name")} --wait")
      end
    end

    it "use no local action in a detector job but the ones that set up Ruby, the boot caches and the journal" do
      described_class.gates.each do |gate|
        local = workflow_steps(gate).filter_map { |step| step["uses"] }.select { |uses| uses.start_with?("./") }

        expect(local).to eq(%w[./.github/actions/setup-ruby ./.github/actions/hecks-boot-cache
                               ./.github/actions/hecks-environment])
      end
    end

    def action_steps(name) = YAML.load_file(File.join(root, ".github/actions", name, "action.yml")).dig("runs", "steps")

    def cache_step = action_steps("hecks-boot-cache").find { |step| step["uses"].to_s.start_with?("actions/cache@") }

    def cache_dirs = %w[hecks_syntax_boot_cache hecks_verdict_cache].map { |name| File.basename(Hecks::CacheDir.path(name)) }

    # The launcher names each cached file by a digest of `lib/`, so a stale restore is ignored; the
    # key decides only whether a run starts warm, and it holds the inputs that digest covers.
    it "key the boot caches by lib/ and the lockfile" do
      expect(cache_step.dig("with", "key")).to include("hashFiles('lib/**', 'Gemfile.lock')")
    end

    it "cache the directories the launcher writes its boot caches to" do
      paths = cache_step.dig("with", "path").lines.map(&:strip)

      expect(paths).to match_array(cache_dirs.map { |dir| "~/.cache/hecks/#{dir}" })
    end

    # Every job of the run waits on a detector, so a detector installs no Rust toolchain: it
    # formats and builds nothing, and restoring the toolchains directory is seconds of the front.
    it "set up Ruby in a detector job without the Rust toolchain" do
      described_class.gates.each do |gate|
        setup = workflow_steps(gate).find { |step| step["uses"] == "./.github/actions/setup-ruby" }

        expect(setup.dig("with", "rust-toolchain")).to eq("false")
      end
    end

    it "keep the Rust toolchain in setup-ruby for every job that does not opt out", :aggregate_failures do
      action = YAML.load_file(File.join(root, ".github/actions/setup-ruby/action.yml"))
      toolchain = action_steps("setup-ruby").find { |step| step["uses"] == "./.github/actions/rust-toolchain" }

      expect(action.dig("inputs", "rust-toolchain", "default")).to eq("true")
      expect(toolchain["if"]).to eq("inputs.rust-toolchain != 'false'")
    end

    def workflow(name) = YAML.load_file(File.join(root, ".github/workflows", name))

    it "gate stress_concurrency on the runtime_changed detector", :aggregate_failures do
      ci = workflow("ci.yml")

      expect(ci.dig("jobs", "stress_concurrency", "needs")).to eq("runtime_changed")
      expect(ci.dig("jobs", "runtime_changed")).not_to have_key("if")
    end

    # A push to main runs the postgres_io shards without a path decision: the detector would only
    # delay their start, and main never skips required work.
    it "gate the postgres_io shards on their detector, except on a push", :aggregate_failures do
      jobs = workflow("ci-postgres-io-parallel.yml").fetch("jobs")

      expect(jobs.dig("postgres_io_relevant_changed", "if")).to eq("github.event_name != 'push'")
      expect(jobs.dig("rspec_postgres_io_parallel_shard", "if")).to include("github.event_name == 'push'")
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

    it "answers 0 when every region is current", :aggregate_failures do
      expect { expect(described_class.main(["--check"], root: work)).to eq(0) }.to output(/every region current/).to_stdout
    end

    def ci_yml = File.join(work, ".github/workflows/ci.yml")

    def hand_edit(text)
      text.sub("timeout-minutes: 10\n    outputs:\n      touched", "timeout-minutes: 99\n    outputs:\n      touched")
    end

    it "names a workflow whose region was edited by hand, and writes nothing under --check", :aggregate_failures do
      edited = hand_edit(File.read(ci_yml))
      File.write(ci_yml, edited)

      expect { expect(described_class.main(["--check"], root: work)).to eq(1) }
        .to output(%r{out of date: \.github/workflows/ci\.yml}).to_stderr
      expect(File.read(ci_yml)).to eq(edited)
    end

    it "restores the region when it is not a check", :aggregate_failures do
      File.write(ci_yml, hand_edit(File.read(ci_yml)))

      expect { described_class.main([], root: work) }.to output(%r{wrote \.github/workflows/ci\.yml}).to_stdout
      expect(File.read(ci_yml)).to eq(described_class.projection(work).fetch(ci_yml))
    end

    it "refuses a workflow with no marked region for a gate", :aggregate_failures do
      File.write(ci_yml, File.read(ci_yml).gsub(/^  # (BEGIN|END) GENERATED ci_gate runtime_changed.*\n/, ""))

      expect { described_class.main([], root: work) }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
        .and output(%r{no BEGIN/END GENERATED ci_gate runtime_changed region}).to_stderr
    end
  end
end
