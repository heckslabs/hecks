require "spec_helper"
require "json"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"

# The filling's steps dispatch on the registry it runs in: the same `CliRunner` a launcher uses,
# answered as a {Shell::Result}, with no `exe/hecks` child started.
RSpec.describe Hecks::Adapters::Dispatching::InProcessRunner do
  let(:registry) { Hecks::Runtime::Registry.new }
  let(:runner) { described_class.new(registry) }
  let(:cli) { Hecks::Adapters::Driving::CliRunner }

  before { allow(Hecks::Runtime::Dispatcher).to receive(:new).with(registry).and_return(:dispatcher) }

  def answering(*answer) = allow(cli).to receive(:call).and_return(answer)

  describe "#call" do
    it "answers a line that ended well with the record it printed", :aggregate_failures do
      answering("{\"state\":{\"status\":\"started\"}}", 0)
      result = runner.call(["tickets", "Work.start!", "--wait"])

      expect(result.ok?).to be(true)
      expect(result.out).to include("started")
    end

    it "answers a refused line with its reason on stderr and the record on stdout", :aggregate_failures do
      answering("{\"refusal\":\"no\"}", 1, "Work ended in the failure state")
      result = runner.call(["tickets", "Work.start!", "--wait"])

      expect(result.ok?).to be(false)
      expect([result.out, result.err]).to eq(["{\"refusal\":\"no\"}", "Work ended in the failure state"])
    end

    it "answers a refused line with no settled record as its text on stderr", :aggregate_failures do
      answering("[already_recorded] run is already recorded", 1)
      result = runner.call(["AgentRun.dispatch!"])

      expect(result.out).to eq("")
      expect(result.err).to include("already_recorded")
    end

    it "answers a raise as a failed line, not as an exception", :aggregate_failures do
      allow(cli).to receive(:call).and_raise(ArgumentError, "bad argument")
      result = runner.call(["AgentRun.dispatch!"])

      expect(result.ok?).to be(false)
      expect(result.err).to eq("ArgumentError: bad argument")
    end
  end

  describe "the cascade a line runs in" do
    def watch(seen)
      allow(cli).to receive(:call) do
        seen[:depth] = Thread.current[:hecks_reaction_depth]
        seen[:caller] = Thread.current[:hecks_caller]
        ["", 0]
      end
    end

    def run_deep(seen)
      Thread.current[:hecks_reaction_depth] = 3
      watch(seen)
      Hecks::Runtime::Caller.as(role: "coder") { runner.call(["x"]) }
    end

    after { Thread.current[:hecks_reaction_depth] = nil }

    it "starts at depth zero with no ambient caller, and puts the depth back", :aggregate_failures do
      seen = {}
      run_deep(seen)

      expect(seen).to eq(depth: 0, caller: nil)
      expect(Thread.current[:hecks_reaction_depth]).to eq(3)
    end
  end

  describe ".fits?" do
    it "fits the checkout this process stands in, and not another", :aggregate_failures do
      Dir.mktmpdir do |other|
        expect(described_class.fits?(registry, Dir.pwd)).to be(true)
        expect(described_class.fits?(registry, other)).to be(false)
      end
    end

    it "does not fit a missing registry or a missing checkout", :aggregate_failures do
      expect(described_class.fits?(nil, Dir.pwd)).to be(false)
      expect(described_class.fits?(registry, nil)).to be(false)
    end
  end

  describe "behind the launcher" do
    let(:item) { Hecks::Adapters::Dispatching::Plan::Item.new(key: "gap", title: "gap", detail: "", area: ["gap"]) }
    let(:lines) { [] }

    def stand_in
      allow(cli).to receive(:call) do |argv:, **|
        lines << argv.find { |word| word.end_with?("!") }
        [argv.include?("Brief.compose!") ? JSON.generate("state" => { "outcome" => "x" }) : "", 0]
      end
    end

    def start = Hecks::Adapters::Dispatching::Launcher.new(Dir.pwd, runner: runner).launch(item, held: [], minutes: 30)

    it "starts a work item through the registry", :aggregate_failures do
      stand_in

      expect(start).to eq("started gap")
      expect(lines).to include("Work.start!", "AgentRun.dispatch!")
    end

    it "starts no launcher process" do
      stand_in
      allow(Hecks::Adapters::Shell).to receive(:new)
      start

      expect(Hecks::Adapters::Shell).not_to have_received(:new)
    end
  end
end
