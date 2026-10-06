require "spec_helper"
require "json"
require "tmpdir"
require "hecks/tools"
require "hecks/tools/fuzz_sweep"
require "hecks/fuzzing/failure_triage"

# `--persist-regressions`: off unless asked, and then one minimized repro per distinct finding.
RSpec.describe Hecks::Tools::FuzzSweep, :aggregate_failures do
  it "keeps regressions off unless the flag is typed" do
    expect(described_class.parse(%w[domains/pizzas])[:persist]).to be(false)
    expect(described_class.parse(%w[domains/pizzas --persist-regressions])[:persist]).to be(true)
  end

  describe "persisting what a sweep found" do
    around { |example| Dir.mktmpdir { |dir| (@root = dir) && example.run } }

    let(:steps) { [{ "verb" => "A.Open", "args" => {} }] }
    let(:failures) do
      [{ seed: 3, steps: steps, verdict: :crash, message: "KeyError: key 9 not found", signature: "crash: KeyError" },
       { seed: 8, steps: steps, verdict: :crash, message: "KeyError: key 4 not found", signature: "crash: KeyError" }]
    end

    def result(persist)
      described_class::Result.new("domains/pizzas", "pizzas", 2, 2, 0, failures, :memory, @root, persist)
    end

    before do
      allow(described_class).to receive(:shrink).and_return(steps)
      allow($stdout).to receive(:puts)
    end

    it "writes one script for a finding however many seeds hit it" do
      described_class.report(result(true))

      kept = Dir[File.join(@root, "spec/corpus/regressions/pizzas/*.json")]
      expect(kept.size).to eq(1)
      expect(JSON.parse(File.read(kept.first))["steps"]).to eq(steps)
    end

    it "writes nothing when the flag is off" do
      described_class.report(result(false))

      expect(Dir[File.join(@root, "spec/corpus/regressions/**/*.json")]).to be_empty
    end

    it "leaves a repro kept by an earlier run exactly as it was" do
      described_class.report(result(true))
      path = Dir[File.join(@root, "spec/corpus/regressions/pizzas/*.json")].first
      File.write(path, "kept by hand")

      described_class.report(result(true))

      expect(File.read(path)).to eq("kept by hand")
    end
  end
end
