require "spec_helper"
require "hecks/tools"

# `hecks gate <stage>` runs the checks the gate rows of the Vocabulary bluebook hold for a stage.
# These specs run the tool against stages of their own, whose checks are tiny shell programs, so
# no real gate (the suite, rubocop) is started.
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

  before { allow(gate).to receive(:stages).and_return(stages) }

  it "answers 0 and names the checks when every one passes", :process do
    status, out, = run_gate("demo", "only=passes,reads_env")
    expect([status, out]).to eq([0, "[gate demo] green: passes, reads_env\n"])
  end

  it "runs every check and reports each red one with its output and what it means", :aggregate_failures, :process do
    status, out, = run_gate("demo")
    expect(status).to eq(1)
    expect(out).to include("a check that fails", "broken", "BLOCKED: fix the broken thing", "red: fails")
    expect(out).not_to include("never shown")
  end

  context "when the caller sets GATE_SPEC_ENV" do
    before { ENV["GATE_SPEC_ENV"] = "from-the-caller" }

    after { ENV.delete("GATE_SPEC_ENV") }

    it "keeps the caller's environment over the stage's", :aggregate_failures, :process do
      status, out, = run_gate("demo", "only=reads_env")
      expect(status).to eq(1)
      expect(out).to include("env was not set")
    end
  end

  it "refuses a check no stage lists, and a stage that does not exist, with status 2", :aggregate_failures do
    expect(run_gate("demo", "only=nope")).to eq([2, "", "no such check: nope (checks: passes, fails, reads_env)\n"])
    expect(run_gate("elsewhere")[0]).to eq(2)
    expect(run_gate[0]).to eq(2)
  end

  it "lists the stages and their checks" do
    expect(run_gate("--list")).to eq([0, "demo: passes, fails, reads_env\n", ""])
  end

  describe "the gate rows the gem ships" do
    let(:shipped) { gate.stages }

    before { allow(gate).to receive(:stages).and_call_original }

    it "lists in every stage only checks the rows hold, each row used by some stage", :aggregate_failures do
      names = Hecks::Vocabulary.rows("GateCheck").map { |row| row["name"] }
      listed = Hecks::Vocabulary.rows("GateStage").flat_map { |row| row["checks"].split(",") }

      expect(names).to eq(names.uniq)
      expect(listed - names).to be_empty
      expect(names - listed).to be_empty
    end

    it "gives every check a command or a script, never both", :aggregate_failures do
      Hecks::Vocabulary.rows("GateCheck").each do |row|
        expect(row.values_at("argv", "script").count(&:empty?)).to eq(1), "#{row["name"]} needs argv or script"
      end
    end

    it "gives every check an id, a title, a command and what a red one means", :aggregate_failures do
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

    it "is the list the pre-push hook runs, and the hook lists no check of its own", :aggregate_failures do
      hook = File.read(File.expand_path("../.githooks/pre-push", __dir__))
      expect(hook).to include('Hecks::Tools.script("gate", ARGV)', "pre_push")
      expect(hook).not_to match(/^run_check /)
    end

    # The note vouches for head's tree, so a suite that ran against a dirty tree must not sign it.
    it "writes no attestation note for a working tree that differs from HEAD", :aggregate_failures do
      hook = File.read(File.expand_path("../.githooks/pre-push", __dir__))

      expect(hook).to include("git status --porcelain --untracked-files=normal")
      expect(hook.index("ATTEST_DIRTY")).to be < hook.index("git notes --ref=ci add")
      expect(hook).to match(/if \[ -n "\$ATTEST_DIRTY" \]; then.*elif \[ -n "\$ATTEST_KEY" \]; then/m)
    end
  end
end
