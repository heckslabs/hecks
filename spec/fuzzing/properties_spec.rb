
require "spec_helper"
require "hecksagain/fuzzing"

# Declared properties over generated histories — the other half of
# property-based testing the fuzzer was missing. Two directions, as
# usual: the standard battery HOLDS over real generated sequences
# (below), and each property actually FIRES against a hand-built
# history that violates it — a property nothing can ever fail is
# decoration, the exact lesson bin/undeclared exists to catch for
# declarations.
RSpec.describe "Hecksagain::Fuzzing::Properties" do
  ROOT_DIR = InMemoryDomain::ROOT
  PROPERTIES_PIZZAS  = File.join(ROOT_DIR, "examples/pizzas")
  PROPERTIES_BANKING = File.join(ROOT_DIR, "examples/banking")

  def generated_history(domain, seed)
    steps = Hecksagain::Fuzzing::SequenceGenerator.generate(domain, seed: seed, steps: 25)
    Hecksagain::Fuzzing::Replay.call(domain, steps)
  end

  describe "the standard battery, over real generated sequences" do
    [[PROPERTIES_PIZZAS, 5], [PROPERTIES_BANKING, 5]].each do |domain, seed_count|
      it "holds for #{File.basename(domain)} across #{seed_count} seeds" do
        (1..seed_count).each do |seed|
          history = generated_history(domain, seed)
          results = Hecksagain::Fuzzing::Properties.check(history)

          results.each do |property, result|
            expect(result).to eq(true), "#{domain} seed #{seed} — #{property}: #{result}"
          end
        end
      end

      it "stays deterministic for #{File.basename(domain)} across #{seed_count} seeds" do
        (1..seed_count).each do |seed|
          steps = Hecksagain::Fuzzing::SequenceGenerator.generate(domain, seed: seed, steps: 25)
          result = Hecksagain::Fuzzing::Properties.replay_is_deterministic(domain, steps)

          expect(result).to eq(true), "#{domain} seed #{seed}: #{result}"
        end
      end
    end
  end

  describe "each property, seen failing" do
    def bluebook_for(domain)
      Hecksagain::Fuzzing::Replay.call(domain, [])[:bluebook]
    end

    it "lifecycle_values_are_declared names an instance holding an undeclared state" do
      history = { bluebook: bluebook_for(PROPERTIES_PIZZAS),
                  instances: { "Pizzas::Pizza#p1" => { status: "teleported" } } }

      result = Hecksagain::Fuzzing::Properties.lifecycle_values_are_declared(history)
      expect(result).to be_a(String)
      expect(result).to include("teleported")
    end

    it "lifecycle_values_are_declared passes a genuinely declared state through" do
      history = { bluebook: bluebook_for(PROPERTIES_PIZZAS),
                  instances: { "Pizzas::Pizza#p1" => { status: "available" } } }

      expect(Hecksagain::Fuzzing::Properties.lifecycle_values_are_declared(history)).to eq(true)
    end

    it "saga_advances_follow_declared_handlers names an advance no handler declares" do
      history = { bluebook: bluebook_for(PROPERTIES_BANKING),
                  sagas: [{ process_manager: "Settlement", on: "Invented", instance: "x",
                            advanced: true, from: "requested", to: "nowhere_declared" }] }

      result = Hecksagain::Fuzzing::Properties.saga_advances_follow_declared_handlers(history)
      expect(result).to be_a(String)
      expect(result).to include("nowhere_declared")
    end

    it "saga_advances_follow_declared_handlers passes a genuinely declared edge through" do
      history = { bluebook: bluebook_for(PROPERTIES_BANKING),
                  sagas: [{ process_manager: "Settlement", on: "TransferRequested", instance: "x",
                            advanced: true, from: "requested", to: "requested" }] }

      expect(Hecksagain::Fuzzing::Properties.saga_advances_follow_declared_handlers(history)).to eq(true)
    end

    it "replay_is_deterministic names a real divergence — a genuinely different step count" do
      # Not a manufactured non-determinism (the runtime does not have
      # one to hand) — a wrong claim that two DIFFERENT step lists are
      # "the same replay" is exactly what this property exists to catch,
      # so this proves the comparison itself is sensitive to real drift.
      first  = Hecksagain::Fuzzing::Replay.call(PROPERTIES_PIZZAS, [])
      second = Hecksagain::Fuzzing::Replay.call(
        PROPERTIES_PIZZAS,
        [{ "verb" => "Pizzas::Pizza.CreatePizza",
           "args" => { "name" => { "value" => "X" }, "price_cents" => { "cents" => 100 }, "size" => { "value" => "small" } } }]
      )
      comparable = ->(h) { h.reject { |k, _| k == :bluebook } }

      expect(comparable.call(first)).not_to eq(comparable.call(second))
    end
  end
end
