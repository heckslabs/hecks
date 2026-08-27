require "hecks"

# S2 (docs/audits/2026-08-10-main-bug-audit.md) — `Identity.scalar` and
# `Identity.from` used to read a nested hash with `h[k.to_sym] || h[k]`,
# which drops a genuinely-stored `false` to `nil` (`false || h[k]` falls
# through). A composite/dotted identity part that is itself a boolean
# used to resolve to `nil` and take down the WHOLE identity with it
# (`Identity.of` refuses any part that is `nil`), not merely mis-read
# that one part.
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
    # A minimal double is enough: the dotted branch of `.from` never
    # touches `identity_heads`/`.attribute` at all — it walks the raw
    # hash the same way `FieldPath` does.
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

    # R4 (docs/audits/2026-08-11-bug-triage.md) — the Rust kernel's own
    # `to_id_component` (rust/src/kernel/json.rs) used to accept an
    # empty-string identity component and persist a record under it, a
    # real, live divergence from THIS behavior: an empty string names
    # nothing here, the same as a genuinely absent part, and the WHOLE
    # identity is refused (`nil`) rather than resolving to a blank-but-
    # real id. `to_id_component_refuses_an_empty_string`
    # (rust/src/kernel/json.rs's own `#[cfg(test)]` module) is the same
    # proof on the Rust side.
    it "refuses (nil) a blank-string identity part — the same as an absent one" do
      construct = IdentityOfFakeConstruct.new(["flag.active"])

      expect(described_class.of(construct, { flag: { active: "" } })).to be_nil
    end
  end

  # M18 (docs/audits/2026-08-10-main-bug-audit.md,
  # docs/audits/2026-08-11-bug-triage.md) — `Identity.of` used to check
  # a derived part with a bare `part.empty?`, which raises `NoMethodError`
  # on any part that isn't a String (an Integer, an Array, a Hash — the
  # exact shape a reference-typed identity head can resolve to when its
  # own attribute lookup falls through). Re-verified against the CURRENT
  # file: the blank-part guard now checks `part.respond_to?(:empty?)`
  # first, so a non-string part is compared by identity/`nil?` alone and
  # never reaches a bare `.empty?` call — these lock that in as a
  # regression rather than a `NoMethodError` reappearing silently.
  describe ".of with a non-string identity part (a reference-typed head)" do
    # `attribute(name)` returns nil — the same "not found, coerce
    # nothing" branch `Identity.from`'s bare (undotted) reader falls
    # through on a head whose own attribute lookup doesn't resolve
    # (a saga's already-resolved correlation key, `from`'s own comment)
    # — `raw` is handed back exactly as given, whatever type it is.
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
