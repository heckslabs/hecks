require "hecks"

# A stored `false` in a dotted identity part must not read as nil: `Identity.of`
# refuses any nil part, so it would take the whole identity down.
RSpec.describe Hecks::Runtime::Identity do
  describe ".scalar" do
    it "reads a stored false member rather than nil" do
      expect(described_class.scalar("wrapper.active", { active: false })).to be(false)
    end

    it "still reads a stored true member" do
      expect(described_class.scalar("wrapper.active", { active: true })).to be(true)
    end
  end

  describe ".of" do
    # A minimal double suffices: the dotted branch of `.from` walks the raw hash and
    # never touches `identity_heads`.
    IdentityOfFakeConstruct = Struct.new(:identity_paths) unless defined?(IdentityOfFakeConstruct)

    it "resolves a false-valued dotted identity part to its real value, not nil" do
      construct = IdentityOfFakeConstruct.new(["flag.active"])

      expect(described_class.of(construct, { flag: { active: false } })).to eq("false")
    end

    it "still resolves a true-valued dotted identity part" do
      construct = IdentityOfFakeConstruct.new(["flag.active"])

      expect(described_class.of(construct, { flag: { active: true } })).to eq("true")
    end

    it "still refuses (nil) a genuinely absent identity part" do
      construct = IdentityOfFakeConstruct.new(["flag.active"])

      expect(described_class.of(construct, { flag: {} })).to be_nil
    end

    # Parity with the Rust kernel's `to_id_component` (rust/src/kernel/json.rs), which
    # also refuses an empty-string component.
    it "refuses (nil) a blank-string identity part — the same as an absent one" do
      construct = IdentityOfFakeConstruct.new(["flag.active"])

      expect(described_class.of(construct, { flag: { active: "" } })).to be_nil
    end
  end

  # Pins that the blank-part guard checks `respond_to?(:empty?)`: a bare `part.empty?`
  # raises NoMethodError on an Integer, Array or Hash part.
  describe ".of with a non-string identity part (a reference-typed head)" do
    # `attribute(name)` returns nil, the "not found, coerce nothing" branch, so `raw`
    # comes back exactly as given, whatever its type.
    IdentityNonStringFakeConstruct = Struct.new(:identity_paths, :identity_heads) do
      def attribute(_name) = nil
    end

    it "does not raise NoMethodError when a bare identity part is an Integer" do
      construct = IdentityNonStringFakeConstruct.new(["thing"], [:thing])

      expect { described_class.of(construct, { thing: 5 }) }.not_to raise_error
      expect(described_class.of(construct, { thing: 5 })).to eq("5")
    end

    it "does not raise NoMethodError when a bare identity part is an Array" do
      construct = IdentityNonStringFakeConstruct.new(["thing"], [:thing])

      expect { described_class.of(construct, { thing: [1, 2] }) }.not_to raise_error
    end

    it "does not raise NoMethodError when a bare identity part is a Hash" do
      construct = IdentityNonStringFakeConstruct.new(["thing"], [:thing])

      expect { described_class.of(construct, { thing: { a: 1 } }) }.not_to raise_error
    end

    it "does not raise NoMethodError when a bare identity part is false" do
      construct = IdentityNonStringFakeConstruct.new(["thing"], [:thing])

      expect { described_class.of(construct, { thing: false }) }.not_to raise_error
      expect(described_class.of(construct, { thing: false })).to eq("false")
    end
  end
end
