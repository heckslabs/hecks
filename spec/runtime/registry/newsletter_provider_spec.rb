require "spec_helper"

# rust/host's newsletter routes read ir.json's `newsletter` key instead of
# naming Newsletter::Subscriber verbs. That key is only as trustworthy as
# the `provides "newsletter"` row behind it, so the row is held to its
# contract (every key, each naming a real command) and the exporter answers
# nothing for a domain that attaches no such chapter.
RSpec.describe "newsletter capability" do
  # The one aggregate the probe chapter needs, as a block the DSL evaluates.
  def subscriber_body
    proc do
      identified_by :email
      attribute :email, Email
      value_object "Email" do
        attribute :value, String
      end
      command "Subscribe" do
        goal "subscribe"
        attribute :email, Email
        sets :email
      end
      %w[AddName Confirm Unsubscribe].each do |verb|
        command verb do
          goal verb
          reference_to Subscriber
        end
      end
    end
  end

  def registry_with_newsletter(provides: nil)
    provides ||= {
      subscribe:   "Subscriber.Subscribe",
      add_name:    "Subscriber.AddName",
      confirm:     "Subscriber.Confirm",
      unsubscribe: "Subscriber.Unsubscribe"
    }
    body = subscriber_body
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)

      Hecks.bluebook "Newsletter" do
        vision "probe"
        supporting
        provides "newsletter", **provides
        aggregate "Subscriber", &body
      end
    end
    registry
  end

  it "resolves the chapter that provides newsletter, whatever it is named" do
    registry = registry_with_newsletter

    expect(registry.newsletter_provider_for("Newsletter").name).to eq("Newsletter")
  end

  it "exports the declared verbs qualified, with the subscribing aggregate named off subscribe" do
    registry = registry_with_newsletter

    expect(Hecks::Projector::Exporter.newsletter(registry, "Newsletter")).to eq(
      provider:    "Newsletter",
      subscribe:   "Newsletter::Subscriber.Subscribe",
      add_name:    "Newsletter::Subscriber.AddName",
      confirm:     "Newsletter::Subscriber.Confirm",
      unsubscribe: "Newsletter::Subscriber.Unsubscribe",
      aggregate:   "Newsletter::Subscriber"
    )
  end

  it "exports nothing for a domain that attaches no newsletter provider" do
    registry = Hecks::Runtime::Registry.new

    expect(Hecks::Projector::Exporter.newsletter(registry, "Pizzas")).to eq({})
  end

  it "refuses a provides row that leaves out a key the contract needs" do
    expect { registry_with_newsletter(provides: { subscribe: "Subscriber.Subscribe" }) }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /newsletter needs exactly/)
  end

  it "refuses a provides row whose verb names no command the chapter declares" do
    expect do
      registry_with_newsletter(provides: {
                                 subscribe:   "Subscriber.Subscribe",
                                 add_name:    "Subscriber.AddName",
                                 confirm:     "Subscriber.Confirm",
                                 unsubscribe: "Subscriber.Leave"
                               })
    end.to raise_error(Hecks::Bluebook::DSL::Malformed, /Subscriber\.Leave/)
  end
end
