require "spec_helper"
require "open3"
require "tmpdir"
require "yaml"
require "hecks/tools"

# The `ci` and `post_commit` stages of lib/hecks/gate/stages.yml are the one copy of what the CI
# workflow and the post-commit hook run. These specs hold the workflow and the hook to the stages,
# so a command cannot be copied into either again, and a check cannot be left unrun.
RSpec.describe "the ci and post_commit gate stages" do
  let(:root) { File.expand_path("..", __dir__) }
  let(:stages) { YAML.load_file(File.join(root, "lib/hecks/gate/stages.yml"), aliases: true) }
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
        "model_check", "engine_agreement", "doc_coverage", "rubocop", "codegen_drift",
        "comment_style", "comment_blocks"
      )
    end

    it "sets no env of its own, so a job's journal choice reaches its checks" do
      expect(stages.fetch("ci")).not_to have_key("env")
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
        expect(ids).not_to be_nil, "ci-checks.yml runs `#{command}`; move it into the ci stage of stages.yml"
      end
    end

    it "runs only checks the stage holds, and every check of the stage exactly once", :aggregate_failures do
      ids = launched.flat_map(&:last)

      expect(ids - ci_ids).to be_empty
      expect(ids.sort).to eq(ci_ids.sort), "ci stage checks run by no step, or by several: " \
                                           "#{((ids - ci_ids) + (ci_ids - ids) + ids.select { |id| ids.count(id) > 1 }).uniq}"
    end
  end

  describe "the post_commit stage" do
    it "holds the fuzzing check pre_push holds" do
      expect(stages.dig("post_commit", "checks")).to eq(stages.dig("pre_push", "checks").select { |c| c["id"] == "fuzzing" })
    end
  end

  # The [kind, verb] of each launcher call in a command line; model_check is a legacy word.
  def hecks_calls(command)
    command.scan(%r{exe/hecks ((?:ask |query |deploy )?)([a-z_.]+)}).map { |kind, verb| [kind.strip, verb] }
           .reject { |_, verb| verb == "model_check" }
  end

  describe "every hecks command a stage's check names" do
    def launcher_calls
      checks = stages.values_at("ci", "post_commit").flat_map { |stage| stage.fetch("checks") }
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

  describe ".githooks/post-commit" do
    let(:work) { Dir.mktmpdir("post_commit_hook") }

    after { FileUtils.rm_rf(work) }

    def hook = File.join(root, ".githooks/post-commit")

    # A `bundle` in the scratch directory that answers `status`.
    def stub_bundle(status)
      FileUtils.mkdir_p(File.join(work, "bin"))
      File.write(File.join(work, "bin/bundle"), "#!/bin/sh\necho \"bundle $*\"\nexit #{status}\n")
      FileUtils.chmod(0o755, File.join(work, "bin/bundle"))
    end

    # Runs the hook in a fresh repository whose `bundle` is a stub answering `status`.
    def run_hook(status:, env: {})
      stub_bundle(status)
      system("git", "init", "-q", work, exception: true)
      out, result = Open3.capture2e({ "PATH" => "#{File.join(work, "bin")}:#{ENV.fetch("PATH", nil)}" }.merge(env), hook,
                                    chdir: work)
      [out, result.exitstatus]
    end

    it "is a shim over the post_commit stage and lists no check of its own", :aggregate_failures do
      text = File.read(hook)

      expect(text).to include('Hecks::Tools.script("gate", ARGV)', "post_commit")
      expect(text).not_to include("rspec")
    end

    it "runs the stage and says it is green" do
      out, status = run_hook(status: 0)

      expect([status, out]).to match([0, a_string_including("post_commit", "ruby -Ilib", "green")])
    end

    it "reports a red stage and still exits 0, since the commit is already made", :aggregate_failures do
      out, status = run_hook(status: 1)

      expect(status).to eq(0)
      expect(out).to include("RED", "SKIP_POST_COMMIT_FUZZING=1")
    end

    it "does nothing when SKIP_POST_COMMIT_FUZZING is set" do
      out, status = run_hook(status: 1, env: { "SKIP_POST_COMMIT_FUZZING" => "1" })

      expect([status, out]).to eq([0, ""])
    end
  end
end
