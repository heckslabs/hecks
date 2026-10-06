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
    def sign(property, message, *verbs) = described_class.signature(property, message, verbs.map { |verb| step(verb) })

    let(:base) { sign("lifecycle", "bad 1", "A.Open", "A.Close") }

    it "is stable across ids" do
      expect(base).to eq(sign("lifecycle", "bad 2", "A.Open", "A.Close"))
      expect(base).to match(/\A\h{12}\z/)
    end

    it "differs by property or by shape" do
      expect(base).not_to eq(sign("saga", "bad 1", "A.Open", "A.Close"))
      expect(base).not_to eq(sign("lifecycle", "bad 1", "A.Open"))
    end
  end

  describe ".dedupe" do
    let(:findings) do
      [finding("bad 1", [step("A.Open"), step("A.Close")], seed: 1),
       finding("bad 2", [step("A.Open"), step("A.Close")], seed: 2),
       finding("worse", [step("B.Make")], seed: 3, signature: "crash: KeyError")]
    end

    it "keeps the smallest sequence of each distinct finding and counts the duplicates" do
      deduped = described_class.dedupe(findings)

      expect(deduped.map { |f| f[:seed] }).to eq([1, 3])
      expect(deduped.first[:duplicates]).to eq(2)
      expect(deduped.first[:triage]).to match(/\A\h{12}\z/)
    end
  end

  describe ".persist" do
    around { |example| Dir.mktmpdir { |dir| (@root = dir) && example.run } }

    let(:found) { described_class.dedupe([finding("bad 1", [step("A.Open")], seed: 4)]).first }
    let(:path)  { described_class.persist(@root, "pizzas", found) }

    it "writes a replayable script under the regressions directory" do
      expect(path).to eq(File.join(@root, "spec/corpus/regressions/pizzas", "#{found[:triage]}.json"))
      script = JSON.parse(File.read(path))
      expect(script.keys).to eq(%w[name note steps])
      expect(script["steps"]).to eq([step("A.Open")])
      expect(script["note"]).to include("seed 4")
    end

    it "never overwrites a finding it already kept" do
      File.write(path, "kept by hand")

      expect(described_class.persist(@root, "pizzas", found)).to be_nil
      expect(File.read(path)).to eq("kept by hand")
    end
  end
end
