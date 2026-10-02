require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "yaml"
require "hecks/tools"
require "hecks/tools/ci_gates"

# The path gates are `CiGate` rows of the Vocabulary chapter. `hecks project_ci_gates` writes each
# row into the marked region of its workflow, and `.github/actions/changed-paths` holds the one
# copy of the base-commit logic. Nothing else pins what a gate answers, so this spec does: it
# holds the committed workflows to the rows, then runs the action's own script against real git
# histories.
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

  # The action's script, run as the runner would: the event as environment variables, inside a
  # checkout of a small history.
  describe ".github/actions/changed-paths" do
    let(:script) do
      action = YAML.load_file(File.join(root, ".github/actions/changed-paths/action.yml"))
      action.dig("runs", "steps").first.fetch("run")
    end
    let(:repo) { Dir.mktmpdir("changed_paths") }
    let(:runtime_gate) { described_class.gates.find { |gate| gate["name"] == "runtime_changed" } }
    let(:postgres_gate) { described_class.gates.find { |gate| gate["name"] == "postgres_io_relevant_changed" } }

    after { FileUtils.rm_rf(repo) }

    def git(*args)
      out, status = Open3.capture2e("git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", *args)
      raise "git #{args.join(' ')}: #{out}" unless status.success?

      out.strip
    end

    # Commits the paths on top of the current head and answers the new sha.
    def commit(*paths)
      paths.each do |path|
        FileUtils.mkdir_p(File.dirname(File.join(repo, path)))
        File.write(File.join(repo, path), "#{path} #{rand}\n")
      end
      git("add", "-A")
      git("commit", "-m", paths.join(","))
      git("rev-parse", "HEAD")
    end

    # Runs the script for a gate and answers the `touched` it wrote, and what it said on stderr.
    def touched(gate, event:, base: nil, before: "", merge_base_ref: "")
      output = File.join(repo, ".github_output")
      env = { "EVENT" => event, "PR_BASE" => base.to_s, "MERGE_BASE_REF" => merge_base_ref, "BEFORE" => before,
              "HEAD_SHA" => git("rev-parse", "HEAD"), "MODE" => gate["mode"], "PATTERN" => gate["pattern"],
              "PUSH" => gate["push"], "LABEL" => gate["label"], "GITHUB_OUTPUT" => output }
      _, err, status = Open3.capture3(env, "bash", "-ec", script, chdir: repo)
      raise "script failed: #{err}" unless status.success?

      [File.read(output)[/touched=(\w+)/, 1], err]
    end

    before do
      git("init", "-q", "-b", "main")
      commit("README.md")
    end

    it "runs the runtime gate for a change under lib/hecks/runtime/" do
      base = git("rev-parse", "HEAD")
      commit("lib/hecks/runtime/dispatch.rb")

      expect(touched(runtime_gate, event: "pull_request", base: base).first).to eq("true")
    end

    it "skips the runtime gate for a change that leaves lib/hecks/runtime/ alone" do
      base = git("rev-parse", "HEAD")
      commit("docs/notes.md", "lib/hecks/other.rb")

      expect(touched(runtime_gate, event: "pull_request", base: base).first).to eq("false")
    end

    it "treats a base it cannot diff against as a reason to run, and says so" do
      commit("docs/notes.md")

      answer, err = touched(runtime_gate, event: "pull_request", base: "deadbeef" * 5)
      expect([answer, err]).to match(["true", /git diff itself failed/])
    end

    it "treats no base at all as a reason to run" do
      commit("docs/notes.md")

      answer, err = touched(runtime_gate, event: "pull_request", base: nil)
      expect([answer, err]).to match(["true", /no usable BASE/])
    end

    it "answers false when the diff is empty" do
      head = git("rev-parse", "HEAD")

      expect(touched(runtime_gate, event: "pull_request", base: head).first).to eq("false")
    end

    context "with the allowlist gate" do
      it "skips a change made only of skippable paths" do
        base = git("rev-parse", "HEAD")
        commit("docs/notes.md", "rust/host/src/web.rs", "CHANGELOG.md")

        expect(touched(postgres_gate, event: "pull_request", base: base).first).to eq("false")
      end

      it "runs when any changed path falls outside the allowlist" do
        base = git("rev-parse", "HEAD")
        commit("docs/notes.md", "lib/hecks/other.rb")

        expect(touched(postgres_gate, event: "pull_request", base: base).first).to eq("true")
      end

      it "diffs a push against the commit before it" do
        before = git("rev-parse", "HEAD")
        commit("lib/hecks/other.rb")

        expect(touched(postgres_gate, event: "push", before: before).first).to eq("true")
      end

      it "runs on a push whose before commit is the null sha" do
        commit("docs/notes.md")

        answer, err = touched(postgres_gate, event: "push", before: "0" * 40)
        expect([answer, err]).to match(["true", /no usable BASE/])
      end
    end

    # A merge group diffs against the target branch, never against the previous queue entry:
    # #729 (docs only) rode behind a red #730 on 2026-09-18 because the gate saw only its own files.
    context "when the run is a merge group" do
      it "sees the files of the entries queued before it" do
        git("update-ref", "refs/remotes/origin/main", "HEAD")
        commit("lib/hecks/runtime/dispatch.rb")
        previous_entry = git("rev-parse", "HEAD")
        commit("docs/notes.md")

        answer, = touched(runtime_gate, event: "merge_group", base: previous_entry, merge_base_ref: "refs/heads/main")
        expect(answer).to eq("true")
      end
    end
  end
end
