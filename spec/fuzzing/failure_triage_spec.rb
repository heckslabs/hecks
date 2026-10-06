require "spec_helper"
require "json"
require "tmpdir"
require "hecks/fuzzing/failure_triage"

RSpec.describe Hecks::Fuzzing::FailureTriage, :aggregate_failures do
  def step(verb) = { "verb" => verb, "args" => {} }

  def finding(message, steps, seed: 1, signature: "property_violation: lifecycle")
    { signature: signature, message: message, steps: steps, seed: seed }
  end

  describe ".normalize" do
    it "strips what a run mints so two runs of one defect read the same" do
      first  = described_class.normalize("lifecycle: 'Open' 7 at 3f2a9c1d-1111-2222-3333-444455556666")
      second = described_class.normalize("lifecycle: 'Closed' 912 at aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")

      expect(first).to eq(second)
      expect(first).to eq("lifecycle: <str> <n> at <uuid>")
    end
  end

  describe ".signature" do
    it "is stable across ids and differs by property or by shape" do
      same_a = described_class.signature("lifecycle", "bad 1", [step("A.Open"), step("A.Close")])
      same_b = described_class.signature("lifecycle", "bad 2", [step("A.Open"), step("A.Close")])

      expect(same_a).to eq(same_b)
      expect(same_a).not_to eq(described_class.signature("saga", "bad 1", [step("A.Open"), step("A.Close")]))
      expect(same_a).not_to eq(described_class.signature("lifecycle", "bad 1", [step("A.Open")]))
      expect(same_a).to match(/\A\h{12}\z/)
    end
  end

  describe ".dedupe" do
    it "keeps the smallest sequence of each distinct finding and counts the duplicates" do
      long  = finding("bad 1", [step("A.Open"), step("A.Close")], seed: 1)
      other = finding("bad 2", [step("A.Open"), step("A.Close")], seed: 2)
      different = finding("worse", [step("B.Make")], seed: 3, signature: "crash: KeyError")

      deduped = described_class.dedupe([long, other, different])

      expect(deduped.map { |f| f[:seed] }).to eq([1, 3])
      expect(deduped.first[:duplicates]).to eq(2)
      expect(deduped.first[:triage]).to match(/\A\h{12}\z/)
    end
  end

  describe ".persist" do
    around { |example| Dir.mktmpdir { |dir| (@root = dir) && example.run } }

    it "writes a replayable script under the regressions directory" do
      found = described_class.dedupe([finding("bad 1", [step("A.Open")], seed: 4)]).first

      path = described_class.persist(@root, "pizzas", found)

      expect(path).to eq(File.join(@root, "spec/corpus/regressions/pizzas", "#{found[:triage]}.json"))
      script = JSON.parse(File.read(path))
      expect(script.keys).to eq(%w[name note steps])
      expect(script["steps"]).to eq([step("A.Open")])
      expect(script["note"]).to include("seed 4")
    end

    it "never overwrites a finding it already kept" do
      found = described_class.dedupe([finding("bad 1", [step("A.Open")])]).first
      path = described_class.persist(@root, "pizzas", found)
      File.write(path, "kept by hand")

      expect(described_class.persist(@root, "pizzas", found)).to be_nil
      expect(File.read(path)).to eq("kept by hand")
    end
  end
end
