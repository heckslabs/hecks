require "spec_helper"
require_relative "../../support/memory_ports"

# rust/host reads the checkout windows (how fresh a signed webhook must be, how
# long a session holds its seat) from ir.json's `checkout` key instead of
# constants (ADR 0098). The key is only as trustworthy as the `provides "checkout"`
# row behind it: each entry must name an attribute with a whole-seconds default.
RSpec.describe "checkout capability" do
  # The shared shape of both probe aggregates: a reference and a typed seconds value.
  CHECKOUT_PROBE_BODY = proc do
    identified_by :reference
    value_object("Reference") { attribute :value, String }
    value_object("Seconds") { attribute :value, Integer }
    attribute :reference, Reference
    command "Open" do
      goal "open"
      attribute :reference, Reference
      sets :reference
    end
  end

  WEBHOOK_RECEIPT_BODY = proc do
    instance_exec(&CHECKOUT_PROBE_BODY)
    attribute :tolerance, Seconds, default: { value: 300 }
    attribute :note, Reference
  end

  CHECKOUT_SESSION_BODY = proc do
    instance_exec(&CHECKOUT_PROBE_BODY)
    attribute :hold, Seconds, default: { value: 1800 }
  end

  def checkout_chapter(provides)
    Hecks.bluebook "Checkout" do
      vision "probe"
      supporting
      provides "checkout", **provides
      aggregate "WebhookReceipt", &WEBHOOK_RECEIPT_BODY
      aggregate "CheckoutSession", &CHECKOUT_SESSION_BODY
    end
  end

  def registry_with_checkout(provides)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      checkout_chapter(provides)
    end
    registry
  end

  it "exports the provider and each declared window in whole seconds" do
    registry = registry_with_checkout(webhook_tolerance: "WebhookReceipt.tolerance", session_hold: "CheckoutSession.hold")

    expect(Hecks::Projector::Exporter.checkout(registry, "Checkout"))
      .to eq(provider: "Checkout", webhook_tolerance: 300, session_hold: 1800)
  end

  it "exports only the windows it declares" do
    registry = registry_with_checkout(session_hold: "CheckoutSession.hold")

    expect(Hecks::Projector::Exporter.checkout(registry, "Checkout")).to eq(provider: "Checkout", session_hold: 1800)
  end

  it "answers nothing for a domain that attaches no checkout chapter" do
    expect(Hecks::Projector::Exporter.checkout(Hecks::Runtime::Registry.new, "Checkout")).to eq({})
  end

  it "refuses a window that names an attribute with no whole-seconds default" do
    expect { registry_with_checkout(webhook_tolerance: "WebhookReceipt.note") }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /WebhookReceipt\.note.*whole-seconds default/)
  end

  it "refuses a key the checkout contract does not name" do
    expect { registry_with_checkout(webhook_ttl: "WebhookReceipt.tolerance") }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /checkout/)
  end
end
