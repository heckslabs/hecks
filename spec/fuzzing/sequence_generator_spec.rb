require "spec_helper"
require "hecksagain/fuzzing/sequence_generator"

RSpec.describe Hecksagain::Fuzzing::SequenceGenerator do
  def domain(name) = File.join(InMemoryDomain::ROOT, "examples/#{name}")

  describe "determinism" do
    it "produces the exact same script for the same seed" do
      first  = described_class.generate(domain("pizzas"), seed: 5, steps: 15)
      second = described_class.generate(domain("pizzas"), seed: 5, steps: 15)

      expect(first).to eq(second)
    end

    it "produces a different script for a different seed" do
      first  = described_class.generate(domain("pizzas"), seed: 1, steps: 15)
      second = described_class.generate(domain("pizzas"), seed: 2, steps: 15)

      expect(first).not_to eq(second)
    end
  end

  describe "validity" do
    # The real self-test. Generation dispatches every candidate step against
    # a live, throwaway runtime as it builds the sequence (SequenceGenerator
    # #call) — `safe_call` only rescues Hecksagain::Runtime::DOMAIN_REFUSALS,
    # so anything else propagates and fails this example. That's exactly what
    # should happen if the generator ever produces a step shaped wrongly
    # enough to crash the interpreter for reasons that have nothing to do
    # with a genuine cross-runtime disagreement.
    it "never crashes the interpreter for pizzas, across many seeds" do
      5.times do |seed|
        expect { described_class.generate(domain("pizzas"), seed: seed, steps: 40) }
          .not_to raise_error
      end
    end

    it "never crashes the interpreter for banking, across many seeds" do
      5.times do |seed|
        expect { described_class.generate(domain("banking"), seed: seed, steps: 40) }
          .not_to raise_error
      end
    end

    it "reaches an actual state, not just refusals — at least one instance-acting or entity step becomes eligible" do
      # Weighted eligibility means an instance-acting/entity command only
      # enters the pool once known_ids has an entry for its aggregate — this
      # confirms sequencing actually reaches that point rather than
      # generating 40 independent creates that never build on each other.
      steps = described_class.generate(domain("pizzas"), seed: 11, steps: 40)
      verbs = steps.filter_map { |step| step["verb"] }

      expect(verbs.any? { |verb| !verb.end_with?(".CreatePizza") }).to be(true)
    end

    it "produces steps in the exact shape spec/parity/*.json already uses" do
      steps = described_class.generate(domain("pizzas"), seed: 9, steps: 10)

      steps.each do |step|
        expect(step.keys - %w[verb query args]).to be_empty
        expect(step).to have_key("args")
        expect(step["verb"] || step["query"]).to be_a(String)
      end
    end

    it "leaves the real example data untouched" do
      before = Dir.glob("#{domain('pizzas')}/data/**/*")
      described_class.generate(domain("pizzas"), seed: 1, steps: 20)
      after = Dir.glob("#{domain('pizzas')}/data/**/*")

      expect(after).to eq(before)
    end
  end
end
