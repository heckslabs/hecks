require "spec_helper"

# Checks the OIDC manifest against the runtime: its verbs equal the runtime's verb list
# and its roles equal the strings the commands declare (integration: spec/oidc_projection_spec.rb).
RSpec.describe Hecks::Projections::OIDC do
  let(:runtime)  { boot_in_memory }
  let(:pizzas)   { runtime.registry.bluebook("Pizzas") }
  let(:manifest) { described_class.call(bluebook: pizzas) }

  it "registers itself under :oidc as it loads" do
    expect(Hecks::Projector.registered?(:oidc)).to be true
    expect(described_class.projection_key).to eq(:oidc)
  end

  describe "scopes" do
    # The load-bearing invariant: a scope naming a command the domain lacks authorizes nothing.
    # Both sides derive from the same IR, so this catches the projection drifting from the runtime.
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

  # Banking, not Pizzas: Pizzas declares no entities. Entity-owned commands route by dotted verb
  # (`command_name.include?(".")`), so a manifest omitting one would silently grant no scope.
  describe "entity-owned commands" do
    let(:banking) { Hecks.boot("examples/banking", install_facade: false).registry.bluebook("Banking") }
    let(:banking_manifest) { described_class.call(bluebook: banking) }
    let(:verbs) { banking_manifest["scopes"].map { |scope| scope["verb"] } }
    let(:scopes) { banking_manifest["scopes"].map { |scope| scope["scope"] } }

    it "names a one-level-nested entity command as a dotted verb" do
      expect(verbs).to include("Banking::SafeDepositBox.Visit.Annotate",
                               "Banking::SafeDepositBox.KeyIssuance.Return",
                               "Banking::Account.LedgerEntry.Amend",
                               "Banking::Account.LedgerEntry.Reverse",
                               "Banking::ATMCard.Withdrawal.Dispute")
    end

    it "spells the matching scope in the same dotted shape, snake_cased" do
      expect(scopes).to include("banking:safe_deposit_box.visit.annotate",
                                "banking:safe_deposit_box.key_issuance.return",
                                "banking:account.ledger_entry.amend",
                                "banking:account.ledger_entry.reverse",
                                "banking:atm_card.withdrawal.dispute")
    end

    it "carries the entity command's own role, the same as an aggregate command would" do
      annotate = banking_manifest["scopes"].find { |scope| scope["verb"] == "Banking::SafeDepositBox.Visit.Annotate" }

      expect(annotate["role"]).not_to be_nil
    end
  end

  describe "roles" do
    # Banking, not Pizzas: Pizzas declares no roles at all.
    let(:banking) { Hecks.boot("examples/banking", install_facade: false).registry.bluebook("Banking") }
    let(:banking_manifest) { described_class.call(bluebook: banking) }

    it "carries the role each command declares" do
      close = banking_manifest["scopes"].find { |scope| scope["verb"] == "Banking::Account.CloseAccount" }

      expect(close["role"]).to eq("Branch clerk")
    end

    # The string Ports::Authorization.holds_role? compares against a Governance::RoleAssignment.
    it "rolls the declared roles up, de-duplicated and sorted" do
      expect(banking_manifest["roles"]).to include("Compliance officer")
      expect(banking_manifest["roles"]).to eq(banking_manifest["roles"].uniq.sort)
    end

    # Banking again: Pizzas commands all declare a role. An omitted scope would read as
    # "no such command" rather than "this command asks for no role".
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
