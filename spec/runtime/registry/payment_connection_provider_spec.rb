require "spec_helper"
require_relative "../../support/memory_ports"

# rust/host's payments-connection routes read ir.json's `payment_connection`
# key instead of naming PaymentConnection's commands. That key is only as
# trustworthy as the `provides "payment_connection"` row behind it, so the row
# is held to its contract (every key, each naming a real command) and the
# exporter answers nothing for a domain that attaches no such chapter.
RSpec.describe "payment_connection capability" do
  VERBS = { connect: "Connect", reconnect: "Reconnect", disconnect: "Disconnect", suspend: "Suspend",
            resume: "Resume", enable: "EnablePayments", disable: "DisablePayments" }.freeze

  PAYMENT_CONNECTION_BODY = proc do
    identified_by :slug
    attribute :slug, Slug
    value_object "Slug" do
      attribute :value, String
    end
    command "Connect" do
      goal "connect"
      attribute :slug, Slug
      sets :slug
    end
    %w[Reconnect Disconnect Suspend Resume EnablePayments DisablePayments].each do |name|
      command name do
        goal name.downcase
        reference_to PaymentConnection
      end
    end
  end

  def full_row = VERBS.transform_values { |command| "PaymentConnection.#{command}" }

  PAYMENT_CONNECTION_EXPORT = {
    provider:   "Billing",
    connect:    "Billing::PaymentConnection.Connect",
    reconnect:  "Billing::PaymentConnection.Reconnect",
    disconnect: "Billing::PaymentConnection.Disconnect",
    suspend:    "Billing::PaymentConnection.Suspend",
    resume:     "Billing::PaymentConnection.Resume",
    enable:     "Billing::PaymentConnection.EnablePayments",
    disable:    "Billing::PaymentConnection.DisablePayments",
    aggregate:  "Billing::PaymentConnection"
  }.freeze

  def billing_chapter(provides)
    Hecks.bluebook "Billing" do
      vision "probe"
      supporting
      provides "payment_connection", **provides
      aggregate "PaymentConnection", &PAYMENT_CONNECTION_BODY
    end
  end

  def registry_with_connection(provides: full_row)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      billing_chapter(provides)
    end
    registry
  end

  it "resolves the chapter that provides payment_connection, whatever it is named" do
    registry = registry_with_connection

    expect(registry.payment_connection_provider_for("Billing").name).to eq("Billing")
  end

  it "exports every declared verb qualified, with the connection aggregate named off connect" do
    exported = Hecks::Projector::Exporter.payment_connection(registry_with_connection, "Billing")

    expect(exported).to eq(PAYMENT_CONNECTION_EXPORT)
  end

  it "exports nothing for a domain that attaches no payment-connection provider" do
    registry = Hecks::Runtime::Registry.new

    expect(Hecks::Projector::Exporter.payment_connection(registry, "Pizzas")).to eq({})
  end

  it "refuses a provides row that leaves out a key the contract needs" do
    expect { registry_with_connection(provides: { connect: "PaymentConnection.Connect" }) }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /payment_connection needs exactly/)
  end

  it "refuses a provides row whose verb names no command the chapter declares" do
    provides = full_row.merge(suspend: "PaymentConnection.Pause")

    expect { registry_with_connection(provides: provides) }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /PaymentConnection\.Pause/)
  end
end
