require "spec_helper"
require "tmpdir"
require "fileutils"
require "timeout"
require "hecks/hecks/adapters/git_rehearsal"

# What the stage's stubbed collaborators are told and what they were asked: per file, the answers
# of its runs (true passes, false fails, the last repeats); the runs made; the flakes counted.
class FlakyRig
  Reply = Struct.new(:out, :ok?)
  Outcome = Hecks::Adapters::GitRehearsal::Impacted::SpecRun::Outcome
  attr_accessor :script, :changed, :red_on_base, :counted
  attr_reader :calls

  def initialize(base)
    @base = base
    @script = {}
    @changed = ["spec/a_spec.rb"]
    @red_on_base = []
    @counted = []
    @calls = []
  end

  def runs(directory, spec) = @calls.count { |at, name| at == directory && name == spec }

  def run
    lambda do |where, spec, **|
      @calls << [where, spec]
      passes = where == @base ? !@red_on_base.include?(spec) : answer(where, spec)
      Outcome.new(spec, passes, passes ? [] : ["./#{spec}:3 # fails"])
    end
  end

  def flakes = ->(names) { @counted.concat(names).then { names.to_h { |name| [name, @counted.count(name)] } } }

  def answers = { "rev-parse" => Reply.new("abc123\n", true), "diff" => Reply.new("#{@changed.join("\n")}\n", true) }

  private

  def answer(where, spec)
    answers = @script.fetch(spec, [true])
    answers[[runs(where, spec) - 1, answers.size - 1].min]
  end
end

# The impacted-specs stage when a file fails among the others: it is run again alone, and the stage
# decides on that run. The spec runner is a stub that answers per file and per call.
RSpec.describe Hecks::Adapters::GitRehearsal::Impacted, "#result with flaky specs" do
  let(:directory) { Dir.mktmpdir("hecks-flaky") }
  let(:base) { Dir.mktmpdir("hecks-flaky-base") }
  let(:rig) { FlakyRig.new(base) }

  after { [directory, base].each { |path| FileUtils.remove_entry(path) } }

  def skips
    Class.new do
      define_method(:call) { |_spec| nil }
      define_method(:io?) { |_spec| false }
    end.new
  end

  def git
    instance_double(Hecks::Adapters::Git).tap do |double|
      allow(double).to receive(:capture) { |verb, *| rig.answers.fetch(verb) }
    end
  end

  def stage(run: rig.run, flakes: rig.flakes, **options)
    lay_out
    tools = described_class::Tools.new(git, run, skips, ->(_commit, &block) { block.call(base) }, flakes)
    described_class.new(directory, branch: "main", tools: tools, **options).result
  end

  def lay_out = rig.changed.product([directory, base]).each { |path, root| lay(root, path) }

  def lay(root, path)
    FileUtils.mkdir_p(File.dirname(File.join(root, path)))
    File.write(File.join(root, path), "# spec\n")
  end

  context "when a file fails in the batch and passes alone" do
    before { rig.script = { "spec/a_spec.rb" => [false, true] } }

    it "reports it as flaky by name and does not turn the stage red", :aggregate_failures do
      result = stage
      expect(result.passed).to be(true)
      expect(result.line).to eq("impacted specs: pass (1 spec file(s) run; flaky under parallel load: spec/a_spec.rb)")
    end

    it "counts it in the record" do
      stage
      expect(rig.counted).to eq(["spec/a_spec.rb"])
    end

    it "does not look at the remote tracking ref" do
      stage
      expect(rig.calls.map(&:first)).not_to include(base)
    end

    it "says how many rehearsals it has been flaky in when it was flaky before" do
      rig.counted = %w[spec/a_spec.rb spec/a_spec.rb]
      expect(stage.line).to include("flaky under parallel load: spec/a_spec.rb (flaky in 3 rehearsals)")
    end

    it "still passes, naming the file, when the record cannot count" do
      expect(stage(flakes: ->(_names) { raise "no" }).line).to include("flaky under parallel load: spec/a_spec.rb")
    end
  end

  context "when a file fails alone too" do
    before { rig.script = { "spec/a_spec.rb" => [false] } }

    it "turns the stage red and counts no flake", :aggregate_failures do
      expect(stage.line).to eq("impacted specs: FAIL failing spec: ./spec/a_spec.rb:3 # fails; 1 spec file(s) run")
      expect(rig.counted).to be_empty
    end

    it "runs it alone exactly once more" do
      stage
      expect(rig.runs(directory, "spec/a_spec.rb")).to eq(2)
    end

    it "stays excluded as pre-existing red when it is red on the remote tracking ref" do
      rig.red_on_base = ["spec/a_spec.rb"]
      expect(stage.line).to eq("impacted specs: pass (1 spec file(s) run; pre-existing red: spec/a_spec.rb)")
    end
  end

  context "when one file is flaky, one red and one green" do
    before do
      rig.changed = %w[spec/a_spec.rb spec/b_spec.rb spec/c_spec.rb]
      rig.script = { "spec/a_spec.rb" => [false, true], "spec/b_spec.rb" => [false] }
    end

    it "reports each class", :aggregate_failures do
      result = stage
      expect(result.passed).to be(false)
      expect(result.line).to include("failing spec: ./spec/b_spec.rb:3", "3 spec file(s) run",
                                     "flaky under parallel load: spec/a_spec.rb")
    end
  end

  describe "the width" do
    before { rig.changed = (1..6).map { |index| "spec/s#{index}_spec.rb" } }

    # A run that records how many are in flight; the first `meet` runs wait for each other.
    def meeting(meet)
      state = { now: 0, peak: 0, arrived: 0 }
      lock = Mutex.new
      gate = ConditionVariable.new
      run = lambda do |_where, spec, **|
        lock.synchronize { arrive(state, meet, lock, gate) }
        FlakyRig::Outcome.new(spec, true, [])
      end
      [run, state]
    end

    def arrive(state, meet, lock, gate)
      state[:now] += 1
      state[:peak] = [state[:peak], state[:now]].max
      state[:arrived] += 1
      state[:arrived] >= meet ? gate.broadcast : Timeout.timeout(5) { gate.wait(lock) while state[:arrived] < meet }
      Thread.pass
      state[:now] -= 1
    end

    it "runs that many at once and no more", :aggregate_failures do
      run, state = meeting(2)
      stage(run: run, width: 2)
      expect(state[:peak]).to eq(2)
    end

    it "runs one at a time at width 1" do
      run, state = meeting(1)
      stage(run: run, width: 1)
      expect(state[:peak]).to eq(1)
    end

    it "defaults to two" do
      expect(described_class::DEFAULT_WIDTH).to eq(2)
    end
  end
end
