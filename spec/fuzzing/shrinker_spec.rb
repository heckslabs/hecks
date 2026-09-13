require "spec_helper"
require "hecks/fuzzing/shrinker"

# `Hecks::Fuzzing::Shrinker` never replays anything itself — every
# example here hands it a pure block standing in for "does this candidate
# still reproduce", so what is pinned is the minimization contract alone.
RSpec.describe Hecks::Fuzzing::Shrinker do
  def step(verb, **args) = { "verb" => verb, "args" => args.transform_keys(&:to_s) }

  describe ".call" do
    it "reduces to exactly the steps the finding needs, wherever they sit" do
      steps = (0...25).map { |i| step("Verb#{i}", a: i) }
      needed = %w[Verb3 Verb17]

      result = described_class.call(steps) do |candidate|
        (needed - candidate.map { |s| s["verb"] }).empty?
      end

      expect(result.steps.map { |s| s["verb"] }).to eq(needed)
      expect(result.exhausted).to be(false)
    end

    it "keeps an order-dependent pair in its original order" do
      steps = [step("Open"), step("Noise"), step("Close"), step("Noise2")]

      result = described_class.call(steps) do |candidate|
        verbs = candidate.map { |s| s["verb"] }
        verbs.include?("Open") && verbs.include?("Close") && verbs.index("Open") < verbs.index("Close")
      end

      expect(result.steps.map { |s| s["verb"] }).to eq(%w[Open Close])
    end

    it "drops the arguments the finding does not need, and keeps the ones it does" do
      steps = [step("Only", keep: 1, drop_me: 2, also_drop: 3)]

      result = described_class.call(steps) { |candidate| candidate.first["args"].key?("keep") }

      expect(result.steps).to eq([step("Only", keep: 1)])
    end

    it "never offers an empty candidate" do
      offered = []
      described_class.call([step("A"), step("B")]) do |candidate|
        offered << candidate
        true
      end

      expect(offered).to all(satisfy { |candidate| !candidate.empty? })
    end

    it "is cheaper than one-at-a-time removal on a long, mostly irrelevant sequence" do
      steps = (0...40).map { |i| step("Verb#{i}") }

      result = described_class.call(steps) { |candidate| candidate.any? { |s| s["verb"] == "Verb39" } }

      expect(result.steps.map { |s| s["verb"] }).to eq(["Verb39"])
      # one-at-a-time from the front pays 39 accepted removals plus a final
      # 1-minimal pass; halving reaches the last step in a handful.
      expect(result.attempts).to be < 30
    end

    it "stops at the budget and still returns a candidate that reproduced" do
      steps = (0...30).map { |i| step("Verb#{i}", x: i) }
      checked = []

      result = described_class.call(steps, budget: 3) do |candidate|
        checked << candidate
        candidate.any? { |s| s["verb"] == "Verb29" }
      end

      expect(result.attempts).to eq(3)
      expect(result.exhausted).to be(true)
      expect(result.steps.map { |s| s["verb"] }).to include("Verb29")
      expect(checked.size).to eq(3)
    end

    it "returns the original unchanged when nothing smaller reproduces" do
      steps = [step("A", x: 1), step("B", y: 2)]

      result = described_class.call(steps) { |candidate| candidate == steps }

      expect(result.steps).to eq(steps)
    end

    it "refuses to run without a reproduction block" do
      expect { described_class.call([step("A")]) }.to raise_error(ArgumentError, /needs a block/)
    end
  end

  describe ".signature / .reproduces?" do
    it "names the verbs a refusal split disagrees on, not just the field" do
      divergence = { field: "refusals",
                     ruby:  [{ "verb" => "A.Open", "kind" => "NotFound" }, { "verb" => "A.Same", "kind" => "X" }],
                     rust:  [{ "verb" => "A.Open", "kind" => "TypeMismatch" }, { "verb" => "A.Same", "kind" => "X" }] }

      expect(described_class.signature([divergence])).to eq(Set["refusals", "refusals:A.Open"])
    end

    it "names the aggregates whose instances disagree" do
      divergence = { field: "instances", ruby: { "A" => [1], "B" => [2] }, rust: { "A" => [1], "B" => [3] } }

      expect(described_class.signature([divergence])).to eq(Set["instances", "instances:B"])
    end

    it "names an instance by its aggregate, never by the generated id in its wire key" do
      divergence = { field: "instances",
                     ruby:  { "D::Beacon#alpha" => { "r" => 1 }, "D::Beacon#bravo" => { "r" => 2 } },
                     rust:  { "D::Beacon#phantom" => { "r" => 0 } } }

      expect(described_class.signature([divergence])).to eq(Set["instances", "instances:D::Beacon"])
    end

    it "names a crash by its exception class" do
      divergence = { field: "crash", detail: "Hecks::Runtime::WiringError: no applier handles :corrects" }

      expect(described_class.signature([divergence])).to eq(Set["crash", "crash:Hecks::Runtime::WiringError"])
    end

    it "does not accept a candidate that diverges on a DIFFERENT refusal" do
      original = described_class.signature([{ field: "refusals", ruby: [{ "verb" => "A.Open" }], rust: [] }])
      other    = [{ field: "refusals", ruby: [{ "verb" => "A.Close" }], rust: [] }]

      expect(described_class.reproduces?(original, other)).to be(false)
    end

    it "accepts a candidate that keeps the original finding and adds another" do
      original = described_class.signature([{ field: "mutations_match_recompute", detail: "x" }])
      wider    = [{ field: "mutations_match_recompute", detail: "y" }, { field: "events", ruby: [], rust: [1] }]

      expect(described_class.reproduces?(original, wider)).to be(true)
    end

    it "never counts an empty divergence list as reproducing" do
      expect(described_class.reproduces?(Set[], [])).to be(false)
    end
  end
end
