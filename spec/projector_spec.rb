require "spec_helper"
require "json"

RSpec.describe Hecksagain::Projector do
  let(:pizzas) { boot_in_memory.registry.bluebook("Pizzas") }

  after do
    # register/call are the only state this module carries — a stub
    # registered by one example must not leak into the next.
    described_class.registry.delete(:stub)
  end

  describe "register/call" do
    it "dispatches to whatever answers call(bluebook:, options:)" do
      stub = Class.new do
        def self.call(bluebook:, options: {})
          { name: bluebook.name, options: options }
        end
      end
      described_class.register(:stub, stub)

      expect(described_class.call(:stub, bluebook: pizzas, options: { flavor: "large" }))
        .to eq(name: "Pizzas", options: { flavor: "large" })
    end

    it "re-registering a name replaces it outright, not additively" do
      described_class.register(:stub, Class.new { def self.call(bluebook:, options: {}) = :first })
      described_class.register(:stub, Class.new { def self.call(bluebook:, options: {}) = :second })

      expect(described_class.call(:stub, bluebook: pizzas)).to eq(:second)
    end

    it "refuses an unregistered target by name, listing what IS registered" do
      expect { described_class.call(:nonexistent, bluebook: pizzas) }
        .to raise_error(described_class::UnknownProjector, /nonexistent/)
    end

    it "answers registered? and registered without calling anything" do
      described_class.register(:stub, Class.new { def self.call(bluebook:, options: {}) end })

      expect(described_class.registered?(:stub)).to be true
      expect(described_class.registered?(:nonexistent)).to be false
      expect(described_class.registered).to include(:stub, :ir)
    end
  end

  describe ":ir, registered for real" do
    it "is registered at load time, not something a spec has to opt into" do
      expect(described_class.registered?(:ir)).to be true
    end

    it "needs no live runtime — a bare Bluebook is enough" do
      expect(described_class.call(:ir, bluebook: pizzas)).to eq(pizzas.to_h)
    end

    it "carries target-version metadata for free, as the first key" do
      projected = described_class.call(:ir, bluebook: pizzas)

      expect(projected.keys.first).to eq(:ir_version)
      expect(projected[:ir_version]).to eq(Hecksagain::Bluebook::IR_VERSION)
    end

    # Determinism, proven against the SAME golden fixture
    # spec/ir_golden_spec.rb already pins — not a fixture invented
    # solely for this framework, which would only prove agreement with
    # itself.
    it "matches the golden Pizzas IR, byte for byte, once sorted the same way" do
      golden = JSON.parse(File.read(File.join(InMemoryDomain::ROOT, "spec/golden/ir/Pizzas.json")))
      projected = JSON.parse(JSON.generate(described_class.call(:ir, bluebook: pizzas)))

      expect(sorted(projected)).to eq(sorted(golden))
    end
  end

  def sorted(value)
    case value
    when Hash   then value.sort_by { |key, _| key.to_s }.to_h { |key, held| [key.to_s, sorted(held)] }
    when Array  then value.map { |held| sorted(held) }
    else value
    end
  end
end
