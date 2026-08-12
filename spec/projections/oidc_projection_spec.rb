require "spec_helper"

# THE ARTIFACT HALF of the OIDC work whose integration half
# spec/oidc_projection_spec.rb already covers. That one proves a verified
# (issuer, subject) resolves to an identity, that the identity's role is
# checked, and that the dispatch is refused when either says no. It just
# had no way to state, up front and as data, WHICH role each command
# wants — every answer came from making a real dispatch and seeing what
# happened.
#
# So the two halves are checked AGAINST EACH OTHER here, not merely
# allowed to coexist: the manifest's verbs are held equal to the
# runtime's own verb list, and its roles are held to be exactly the
# strings the commands declare.
RSpec.describe Hecksagain::Projections::OIDC do
  let(:runtime)  { boot_in_memory }
  let(:pizzas)   { runtime.registry.bluebook("Pizzas") }
  let(:manifest) { described_class.call(bluebook: pizzas) }

  it "registers itself under :oidc as it loads" do
    expect(Hecksagain::Projector.registered?(:oidc)).to be true
    expect(described_class.projection_key).to eq(:oidc)
  end

  it "needs no live runtime — a bare Bluebook is enough" do
    expect { described_class.call(bluebook: pizzas) }.not_to raise_error
  end

  describe "scopes" do
    # THE LOAD-BEARING INVARIANT. A scope naming a command the domain
    # does not have would be an authorization rule for nothing — and
    # because both sides derive from the same IR, this catches the
    # projection drifting from the runtime rather than agreeing with
    # itself.
    it "names every verb the domain declares, and no others" do
      expect(manifest["scopes"].map { |scope| scope["verb"] }).to match_array(pizzas.verbs)
    end

    it "spells a verb exactly as Dispatcher#dispatch takes it" do
      verb = manifest["scopes"].map { |scope| scope["verb"] }.first

      expect(verb).to match(/\APizzas::\w+\.\w+\z/)
    end

    it "spells a scope in the conventional audience:resource.action shape" do
      scopes = manifest["scopes"].map { |scope| scope["scope"] }

      expect(scopes).to all(match(/\Apizzas:[a-z0-9_]+\.[a-z0-9_]+\z/))
    end

    it "is sorted by scope, so two versions of a manifest diff cleanly" do
      scopes = manifest["scopes"].map { |scope| scope["scope"] }

      expect(scopes).to eq(scopes.sort)
    end
  end

  describe "roles" do
    # Banking, not Pizzas — Pizzas declares no roles at all, which is
    # exactly why it is the right domain for the "unguarded command"
    # case below and the wrong one for this.
    let(:banking) { Hecks.boot("examples/banking", install_facade: false).registry.bluebook("Banking") }
    let(:banking_manifest) { described_class.call(bluebook: banking) }

    it "carries the role each command declares" do
      close = banking_manifest["scopes"].find { |scope| scope["verb"] == "Banking::Account.CloseAccount" }

      expect(close["role"]).to eq("Branch clerk")
    end

    # The same string Ports::Authorization.holds_role? compares against a
    # real Governance::RoleAssignment — see spec/oidc_projection_spec.rb,
    # which grants precisely this role to run a Banking command.
    it "rolls the declared roles up, de-duplicated and sorted" do
      expect(banking_manifest["roles"]).to include("Compliance officer")
      expect(banking_manifest["roles"]).to eq(banking_manifest["roles"].uniq.sort)
    end

    # Banking again, and for the same reason inverted: every Pizzas
    # command declares a role, so Pizzas cannot show this case at all.
    # Banking has genuinely unguarded commands (Account.AccrueInterest
    # and friends), which is the shape that must not silently vanish —
    # an omitted scope would read as "no such command" rather than
    # "this command asks for no role".
    it "keeps an unguarded command with a nil role rather than dropping it" do
      unguarded = banking_manifest["scopes"].select { |scope| scope["role"].nil? }

      expect(unguarded).not_to be_empty
      expect(banking_manifest["scopes"].size).to eq(banking.verbs.size)
    end

    it "leaves a nil role out of the rolled-up role list" do
      expect(banking_manifest["roles"]).not_to include(nil)
    end
  end

  describe "audience" do
    it "defaults to the domain's own name" do
      expect(manifest["audience"]).to eq("Pizzas")
    end

    it "takes an override, for an IdP that registers a URL" do
      projected = described_class.call(bluebook: pizzas, options: { audience: "https://api.example.com" })

      expect(projected["audience"]).to eq("https://api.example.com")
    end
  end

  it "is deterministic — the same bluebook projects identically every time" do
    expect(described_class.call(bluebook: pizzas)).to eq(described_class.call(bluebook: pizzas))
  end
end
