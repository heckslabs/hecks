require "spec_helper"
require "tmpdir"
require "yaml"
require "hecks/tools"

# `hecks gate <stage>` runs the checks lib/hecks/gate/stages.yml holds for a stage. These specs
# run the tool against a stages file of their own, whose checks are tiny shell programs, so no
# real gate (the suite, rubocop) is started.
RSpec.describe "hecks gate" do
  let(:gate) { Hecks::Tools.fetch("gate") }
  let(:stages) do
    {
      "demo" => {
        "env"    => { "GATE_SPEC_ENV" => "from-the-stage" },
        "checks" => [
          { "id" => "passes", "title" => "a check that passes", "run" => ["sh", "-c", "echo fine"],
            "blocked" => "never shown" },
          { "id" => "fails", "title" => "a check that fails", "run" => ["sh", "-c", "echo broken; exit 3"],
            "blocked" => "fix the broken thing" },
          { "id" => "reads_env", "title" => "a check that reads the stage's env",
            "run" => ["sh", "-c", "test \"$GATE_SPEC_ENV\" = from-the-stage"], "blocked" => "env was not set" }
        ]
      }
    }
  end

  let(:stages_dir) { Dir.mktmpdir }

  before do
    path = File.join(stages_dir, "stages.yml")
    File.write(path, YAML.dump(stages))
    Hecks::Tools.fetch("gate")
    stub_const("Hecks::Tools::Gate::STAGES_FILE", path)
  end

  after { FileUtils.rm_rf(stages_dir) }

  def run_gate(*argv)
    out = StringIO.new
    err = StringIO.new
    $stdout = out
    $stderr = err
    status = gate.main(argv, root: Dir.pwd)
    [status, out.string, err.string]
  ensure
    $stdout = STDOUT
    $stderr = STDERR
  end

  it "answers 0 and names the checks when every one passes" do
    status, out, = run_gate("demo", "only=passes,reads_env")
    expect([status, out]).to eq([0, "[gate demo] green: passes, reads_env\n"])
  end

  it "runs every check and reports each red one with its output and what it means" do
    status, out, = run_gate("demo")
    expect(status).to eq(1)
    expect(out).to include("a check that fails", "broken", "BLOCKED: fix the broken thing", "red: fails")
    expect(out).not_to include("never shown")
  end

  it "keeps the caller's environment over the stage's" do
    ENV["GATE_SPEC_ENV"] = "from-the-caller"
    status, out, = run_gate("demo", "only=reads_env")
    expect(status).to eq(1)
    expect(out).to include("env was not set")
  ensure
    ENV.delete("GATE_SPEC_ENV")
  end

  it "refuses a check no stage lists, and a stage that does not exist, with status 2" do
    expect(run_gate("demo", "only=nope")).to eq([2, "", "no such check: nope (checks: passes, fails, reads_env)\n"])
    expect(run_gate("elsewhere")[0]).to eq(2)
    expect(run_gate[0]).to eq(2)
  end

  it "lists the stages and their checks" do
    expect(run_gate("--list")).to eq([0, "demo: passes, fails, reads_env\n", ""])
  end

  describe "the stages file the gem ships" do
    let(:shipped) { YAML.load_file(File.expand_path("../lib/hecks/gate/stages.yml", __dir__)) }

    it "gives every check an id, a title, a command and what a red one means" do
      checks = shipped.values.flat_map { |stage| stage.fetch("checks") }
      expect(checks).not_to be_empty
      expect(checks.map { |check| check.keys.sort }.uniq).to eq([%w[blocked id run title]])
    end

    it "names no check twice within a stage" do
      shipped.each_value do |stage|
        ids = stage.fetch("checks").map { |check| check["id"] }
        expect(ids).to eq(ids.uniq)
      end
    end

    it "is the list the pre-push hook runs, and the hook lists no check of its own" do
      hook = File.read(File.expand_path("../.githooks/pre-push", __dir__))
      expect(hook).to include('Hecks::Tools.script("gate", ARGV)', "pre_push")
      expect(hook).not_to match(/^run_check /)
    end
  end
end
