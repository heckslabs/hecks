require "spec_helper"
require_relative "../../rust/project/exemplar"
require_relative "../../rust/project/naming"
require_relative "../../rust/project/reactions"

# `emit_merged_policy_table`/`emit_merged_cross_domain_policy_table` —
# the recovery of a documented, deliberate gap: bin/project_rust used to
# build its ONE merged Store's policy/cross-domain-policy tables from
# ONLY the target domain's own policies, silently dropping every
# attached/vendored chapter's own. Invisible until a domain vendored a
# chapter that actually declares policies (Governance/Identity, the only
# framework chapters exercised before this, declare none) — found live
# generating lifeadelics' vendored embryonaut_bluebooks/payments:
# `OnPaymentConfirmedByProcessor`'s own trigger never fired against the
# merged Store, even though payments/registry.rs's own STANDALONE table
# had it all along. Tested directly here, same reasoning
# bridging_spec.rb's own header gives for an identically-shaped latent
# gap with no corpus domain exercising it.
RSpec.describe RustProjection::Projector do
  TARGET_POLICY = {
    name: "OnOrderPlaced", on_event: "OrderPlaced", trigger_command: "Invoice.Open",
    target_domain: nil, for_each: nil, with_spec: []
  }.freeze

  VENDORED_POLICY = {
    name: "OnPaymentConfirmedByProcessor", on_event: "PaymentConfirmedByProcessor",
    trigger_command: "Payment.Succeed", target_domain: nil, for_each: nil, with_spec: []
  }.freeze

  VENDORED_CROSS_DOMAIN_POLICY = {
    name: "OnPaymentFailed", on_event: "PaymentFailed", trigger_command: "Ledger.Reverse",
    target_domain: "Ledger", for_each: nil, with_spec: []
  }.freeze

  SOURCES = [
    { domain_name: "Orders", policies: [TARGET_POLICY], aggregates: [] },
    { domain_name: "Payments", policies: [VENDORED_POLICY, VENDORED_CROSS_DOMAIN_POLICY], aggregates: [] }
  ].freeze

  describe ".emit_merged_policy_table" do
    it "carries the target domain's own policy, qualified against its own domain" do
      table = described_class.emit_merged_policy_table(SOURCES)

      expect(table).to include('target_verb: "Orders::Invoice.Open"')
    end

    it "ALSO carries a vendored chapter's own same-domain policy, qualified against ITS domain — the fixed gap" do
      table = described_class.emit_merged_policy_table(SOURCES)

      expect(table).to include('policy_name: "OnPaymentConfirmedByProcessor"')
      expect(table).to include('target_verb: "Payments::Payment.Succeed"')
    end

    it "excludes a vendored chapter's own cross-domain policy from the local table — that one belongs to the cross-domain table instead" do
      table = described_class.emit_merged_policy_table(SOURCES)

      expect(table).not_to include("OnPaymentFailed")
    end
  end

  describe ".emit_merged_cross_domain_policy_table" do
    it "carries a vendored chapter's own cross-domain policy, qualified against its own trigger domain" do
      table = described_class.emit_merged_cross_domain_policy_table(SOURCES)

      expect(table).to include('policy_name: "OnPaymentFailed"')
      expect(table).to include('target_domain: "Ledger"')
      expect(table).to include('target_verb: "Ledger::Ledger.Reverse"')
    end

    it "excludes a same-domain policy from either source — that one belongs to the local table instead" do
      table = described_class.emit_merged_cross_domain_policy_table(SOURCES)

      expect(table).not_to include("OnOrderPlaced")
      expect(table).not_to include("OnPaymentConfirmedByProcessor")
    end
  end
end
