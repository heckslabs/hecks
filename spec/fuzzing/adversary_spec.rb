require "spec_helper"
require "json"
require "hecks/fuzzing"

# The adversarial layer (lib/hecks/fuzzing/sequence_generator/adversary.rb)
# — three claims, each checked against REAL generated sequences rather
# than a stub: it is exactly as deterministic per seed as the rest of the
# generator, it is genuinely opt-in (off means byte-identical output and
# no extra RNG draw), and every mutation kind produces the documented
# shape in the step's own args — the same args `Fuzzing::Replay` hands
# Ruby's runtime and `JSON.generate({steps: ...})` hands the compiled
# Rust binary.
RSpec.describe Hecks::Fuzzing::SequenceGenerator do
  PIZZAS          = File.join(InMemoryDomain::ROOT, "examples/pizzas")
  BANKING         = File.join(InMemoryDomain::ROOT, "examples/banking")
  CHESS           = File.join(InMemoryDomain::ROOT, "examples/chess")
  NESTED_PIECES   = File.join(InMemoryDomain::ROOT, "qa/stress_domains/nested_pieces")
  LEDGER_ORDERING = File.join(InMemoryDomain::ROOT, "qa/stress_domains/ledger_ordering")

  # Every `[step, mutation]` pair across a handful of seeds, grouped by
  # mutation kind — `adversarial: 1.0` so every command step that CAN be
  # mutated is, which is what makes "each kind appears" a fact about the
  # layer rather than about luck.
  def mutations_over(domain_path, seeds:, fraction: 1.0, steps: 25)
    pairs = (1..seeds).flat_map do |seed|
      generated = described_class.generate(domain_path, seed: seed, steps: steps, adversarial: fraction)
      generated.flat_map { |step| (step["adversarial"] || []).map { |mutation| [step, mutation] } }
    end
    pairs.group_by { |_, mutation| mutation["mutation"] }
  end

  describe "the seed contract" do
    it "produces the exact same script for the same seed and fraction, mutations included" do
      first  = described_class.generate(PIZZAS, seed: 7, steps: 25, adversarial: 0.5)
      second = described_class.generate(PIZZAS, seed: 7, steps: 25, adversarial: 0.5)

      expect(first).to eq(second)
      expect(first.count { |step| step.key?("adversarial") }).to be_positive
    end

    it "stays deterministic on banking too, across several seeds" do
      (1..4).each do |seed|
        first  = described_class.generate(BANKING, seed: seed, steps: 25, adversarial: 0.5)
        second = described_class.generate(BANKING, seed: seed, steps: 25, adversarial: 0.5)
        expect(first).to eq(second), "banking seed #{seed} diverged between two identical calls"
      end
    end

    it "is opt-in — `adversarial: 0.0` is byte-identical to not passing the option and carries no metadata" do
      plain = described_class.generate(PIZZAS, seed: 3, steps: 25)
      off   = described_class.generate(PIZZAS, seed: 3, steps: 25, adversarial: 0.0)

      expect(off).to eq(plain)
      expect(off.none? { |step| step.key?("adversarial") }).to be(true)
    end

    it "refuses a fraction outside 0..1" do
      expect { described_class.generate(PIZZAS, seed: 1, steps: 5, adversarial: 1.5) }.to raise_error(ArgumentError)
      expect { described_class.generate(PIZZAS, seed: 1, steps: 5, adversarial: -0.1) }.to raise_error(ArgumentError)
      expect { described_class.generate(PIZZAS, seed: 1, steps: 5, adversarial: "half") }.to raise_error(ArgumentError)
    end
  end

  describe "both replay paths receive the same bytes" do
    # `Replay.call` reads `step["args"]`; the Rust bridge sends
    # `JSON.generate({"steps" => steps})`. Both read the SAME `args` the
    # generator's own inline dispatch already ran — so the mutation's
    # fingerprint has to be IN `args` (not in metadata only), and the
    # step has to survive a JSON round-trip unchanged.
    it "puts every mutation's fingerprint in the step's own args, and the step round-trips through JSON" do
      steps = described_class.generate(PIZZAS, seed: 5, steps: 25, adversarial: 1.0)
      mutated = steps.select { |step| step.key?("adversarial") }
      expect(mutated).not_to be_empty

      expect(JSON.parse(JSON.generate({ "steps" => steps }))["steps"]).to eq(steps)

      mutated.each do |step|
        step["adversarial"].each do |mutation|
          case mutation["mutation"]
          when "routing_key" then expect(step["args"]).to have_key(mutation["key"])
          when "blank_identity", "null_value_object" then expect(step["args"]).to have_key(mutation["argument"])
          when "omit_mapped_argument" then expect(step["args"]).not_to have_key(mutation["argument"])
          when "refusal_precedence"
            expect(step["args"]).to have_key(mutation["unknown"]) if mutation["unknown"]
            expect(step["args"]).not_to have_key(mutation["absent"]) if mutation["absent"]
          end
        end
      end
    end

    it "replays as domain refusals or successes, never a crash — a mutated step is data, not a defect" do
      steps   = described_class.generate(PIZZAS, seed: 5, steps: 25, adversarial: 1.0)
      history = Hecks::Fuzzing::Replay.call(PIZZAS, steps)

      mutated_verbs = steps.select { |step| step.key?("adversarial") }.map { |step| step["verb"] }
      expect(history[:refusals].map { |r| r[:verb] } & mutated_verbs).not_to be_empty
    end
  end

  describe "each mutation kind produces its documented shape" do
    before(:all) do
      @by_kind = mutations_over(PIZZAS, seeds: 6)
      mutations_over(BANKING, seeds: 3).each { |kind, pairs| (@by_kind[kind] ||= []).concat(pairs) }
    end

    it "routing_key — an undeclared to:/with:/id: as null, a scalar, or a routing-shaped object (BUG#7/#16/#8)" do
      pairs = @by_kind.fetch("routing_key")
      expect(pairs.map { |_, m| m["key"] }.uniq).to match_array(%w[to with id])
      expect(pairs.map { |_, m| m["shape"] }.uniq).to match_array(%w[null scalar route])

      pairs.each do |step, mutation|
        value = step["args"][mutation["key"]]
        case mutation["shape"]
        when "null"   then expect(value).to be_nil
        when "scalar" then expect(value).to be_a(String).or be_a(Integer)
        when "route"
          expect(value).to be_a(Hash)
          expect(value.keys).to match_array(%w[aggregate entities])
          expect(value["entities"]).to be_an(Array)
        end
      end
    end

    it "blank_identity — a creating identity part as \"\", whitespace, or null (BUG#15)" do
      pairs = @by_kind.fetch("blank_identity")
      expect(pairs.map { |_, m| m["shape"] }.uniq).to match_array(%w[empty whitespace null])

      pairs.each do |step, mutation|
        value = step["args"][mutation["argument"]]
        blank = mutation["shape"] == "empty" ? "" : "   "
        case mutation["shape"]
        when "null" then expect(value).to be_nil
        else
          expect(value.is_a?(Hash) ? value.values.uniq : [value]).to eq([blank])
        end
      end
    end

    it "null_value_object — a single-field value object as bare null or {} (BUG#14)" do
      pairs = @by_kind.fetch("null_value_object")
      expect(pairs.map { |_, m| m["shape"] }.uniq).to match_array(%w[null empty_object])

      pairs.each do |step, mutation|
        expect(step["args"][mutation["argument"]]).to eq(mutation["shape"] == "null" ? nil : {})
        expect(mutation).to include("value_object", "closed_set")
      end
    end

    it "null_value_object prefers a closed-set value object when the command declares one" do
      pairs = mutations_over(CHESS, seeds: 4).fetch("null_value_object")
      closed = pairs.select { |_, m| m["closed_set"] }
      expect(closed).not_to be_empty
      expect(closed.map { |_, m| m["value_object"] }.uniq).to include("Color")
    end

    it "omit_mapped_argument — a mapped/declared non-identity attribute is left out of the payload (BUG#12)" do
      pairs = @by_kind.fetch("omit_mapped_argument")
      pairs.each do |step, mutation|
        expect(step["args"]).not_to have_key(mutation["argument"])
        expect(mutation).to include("optional")
      end
    end

    it "refusal_precedence — unknown, mismatched and absent in the same step, reported as what was actually done" do
      pairs = @by_kind.fetch("refusal_precedence")
      expect(pairs.map { |_, m| m["shape"] }).to include("absent+mismatch+unknown")

      pairs.each do |step, mutation|
        applied = mutation["shape"].split("+")
        expect(applied.include?("unknown")).to eq(mutation.key?("unknown"))
        expect(applied.include?("absent")).to eq(mutation.key?("absent"))
        expect(applied.include?("mismatch")).to eq(mutation.key?("mismatched"))
        expect(step["args"]).to have_key(mutation["unknown"]) if mutation["unknown"]
        expect(step["args"]).not_to have_key(mutation["absent"]) if mutation["absent"]
      end
    end

    # A LOWER FRACTION HERE, ON PURPOSE — this mutation needs a PRIOR
    # append to have SUCCEEDED under the same parent (that is what fills
    # the pool it replays from), and at `adversarial: 1.0` nearly every
    # append is itself mutated and refused first. 0.3 is the dial
    # `bin/qa_sweep` runs at; deterministic per seed, so "found within
    # these seeds" is a stable fact, not a flake. Seeds are walked one
    # at a time and the walk stops at the first sequence that carries
    # one, so the ordinary cost is a handful of generates.
    it "duplicate_entity_identity — reuses an identity the same sequence already appended under that parent (BUG#13)" do
      pairs = (1..40).lazy.map { |seed| mutations_over(LEDGER_ORDERING, seeds: seed, fraction: 0.3)["duplicate_entity_identity"] }
                     .find { |found| found&.any? }
      expect(pairs).not_to be_nil

      pairs.each do |step, mutation|
        expect(step["verb"]).to end_with("Folder.AddSlip")
        expect(mutation["entity"]).to eq("Slip")
        expect(mutation["composite"]).to be(false)
        mutation["identity"].each { |name, value| expect(step["args"][name]).to eq(value) }
      end
    end

    it "deep_entity — entity commands two hops deep are generated, flat and routed, with the depth reported (BUG#11)" do
      pairs = mutations_over(NESTED_PIECES, seeds: 4).fetch("deep_entity")
      expect(pairs.map { |_, m| m["addressing"] }.uniq).to match_array(%w[flat routed])

      pairs.each do |step, mutation|
        expect(step["verb"]).to match(/\ANestedPieces::Workspace\.Board\.Card\.\w+\z/)
        expect(mutation["depth"]).to eq(2)
        if mutation["addressing"] == "routed"
          route = step["args"]["to"]
          expect(route.keys).to match_array(%w[aggregate entities])
          expect(route["aggregate"]).to be_a(String)
          expect(route["entities"].size).to eq(2)
          expect(route["entities"]).to all(be_a(String))
          expect(step["args"]).not_to have_key("reference")
          expect(step["args"]).not_to have_key("number")
        else
          expect(step["args"].keys).to include("reference", "number", "sequence")
        end
      end
    end
  end

  describe "the catalog reaches nested entities in ordinary mode too" do
    it "generates a two-hop entity command for nested_pieces without adversarial mode" do
      verbs = (1..6).flat_map { |seed| described_class.generate(NESTED_PIECES, seed: seed, steps: 25).map { |s| s["verb"] } }

      expect(verbs.compact.grep(/Workspace\.Board\.Card\./)).not_to be_empty
    end
  end
end
