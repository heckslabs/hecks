require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/hecks/adapters/git_rehearsal"

# The impacted-specs stage with a stubbed spec runner: green, red, red before the push too, and
# skipped for want of a scratch Postgres. Git answers from a stub and no spec, gate or cargo runs.
RSpec.describe Hecks::Adapters::GitRehearsal::Impacted do
  Answer = Struct.new(:out, :ok?)
  let(:directory) { Dir.mktmpdir("hecks-impacted") }
  let(:base) { Dir.mktmpdir("hecks-impacted-base") }
  let(:changed) { ["spec/a_spec.rb"] }
  let(:red) { [] }
  let(:red_on_base) { [] }

  after { [directory, base].each { |path| FileUtils.remove_entry(path) } }

  def outcome(spec, passed) = described_class::SpecRun::Outcome.new(spec, passed, passed ? [] : ["./#{spec}:3 # fails"])

  def git
    answers = { "rev-parse" => Answer.new("abc123\n", true), "diff" => Answer.new("#{changed.join("\n")}\n", true) }
    instance_double(Hecks::Adapters::Git).tap { |double| allow(double).to receive(:capture) { |verb, *| answers.fetch(verb) } }
  end

  def run
    lambda do |where, spec, **|
      failing = where == base ? red_on_base : red
      outcome(spec, !failing.include?(spec))
    end
  end

  def skips(reason: nil)
    Class.new do
      define_method(:call) { |_spec| reason }
      define_method(:io?) { |_spec| false }
    end.new
  end

  def stage(reason: nil, limit: 60)
    tools = described_class::Tools.new(git, run, skips(reason: reason), ->(_commit, &block) { block.call(base) })
    described_class.new(directory, branch: "main", tools: tools, limit: limit).result
  end

  before do
    changed.each do |path|
      FileUtils.mkdir_p(File.dirname(File.join(directory, path)))
      File.write(File.join(directory, path), "# spec\n")
      FileUtils.mkdir_p(File.dirname(File.join(base, path)))
      File.write(File.join(base, path), "# spec\n")
    end
  end

  it "passes when every impacted spec passes" do
    expect(stage.line).to eq("impacted specs: pass (1 spec file(s) run)")
  end

  context "when an impacted spec is red" do
    let(:red) { ["spec/a_spec.rb"] }

    it "turns the stage red and names the spec and its failing example" do
      expect(stage.line).to eq("impacted specs: FAIL failing spec: ./spec/a_spec.rb:3 # fails; 1 spec file(s) run")
    end
  end

  context "when the spec was already red on the remote tracking ref" do
    let(:red) { ["spec/a_spec.rb"] }
    let(:red_on_base) { ["spec/a_spec.rb"] }

    it "reports it as pre-existing red and passes" do
      expect(stage.line).to eq("impacted specs: pass (1 spec file(s) run; pre-existing red: spec/a_spec.rb)")
    end
  end

  context "when the red spec is new, so it does not exist on the remote tracking ref" do
    let(:red) { ["spec/a_spec.rb"] }
    let(:red_on_base) { ["spec/a_spec.rb"] }

    before { FileUtils.rm_f(File.join(base, "spec/a_spec.rb")) }

    it "stays red" do
      expect(stage.passed).to be(false)
    end
  end

  it "reports a spec it cannot run and passes" do
    expect(stage(reason: "no scratch Postgres").line).to eq("impacted specs: pass (skipped: no scratch Postgres (1))")
  end

  context "when more specs are impacted than the limit" do
    let(:changed) { %w[spec/a_spec.rb spec/b_spec.rb spec/c_spec.rb] }

    it "runs the limit and says the rest run in CI" do
      expect(stage(limit: 2).line).to include("capped at 2 of 3; the rest run in CI")
    end
  end

  it "passes without a comparison when there is no remote tracking ref" do
    allow(Hecks::Adapters::Git).to receive(:new).and_return(instance_double(Hecks::Adapters::Git, capture: Answer.new("", false)))
    tools = described_class::Tools.new(Hecks::Adapters::Git.new, run, skips, nil)
    expect(described_class.new(directory, branch: "main", tools: tools).result.line).to include("no origin/main to compare with")
  end
end
