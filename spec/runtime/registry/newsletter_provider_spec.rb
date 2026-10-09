require "spec_helper"
require_relative "../../support/memory_ports"

# rust/host's newsletter routes read ir.json's `newsletter` key instead of
# naming Newsletter::Subscriber verbs. That key is only as trustworthy as
# the `provides "newsletter"` row behind it, so the row is held to its
# contract (every key, each naming a real command) and the exporter answers
# nothing for a domain that attaches no such chapter.
RSpec.describe "newsletter capability" do
  # The one aggregate the probe chapter needs, as a block the DSL evaluates.
  NEWSLETTER_SUBSCRIBER_BODY = proc do
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

  NEWSLETTER_VERBS = {
    subscribe:   "Subscriber.Subscribe",
    add_name:    "Subscriber.AddName",
    confirm:     "Subscriber.Confirm",
    unsubscribe: "Subscriber.Unsubscribe"
  }.freeze

  NEWSLETTER_EXPORT = {
    provider:    "Newsletter",
    subscribe:   "Newsletter::Subscriber.Subscribe",
    add_name:    "Newsletter::Subscriber.AddName",
    confirm:     "Newsletter::Subscriber.Confirm",
    unsubscribe: "Newsletter::Subscriber.Unsubscribe",
    aggregate:   "Newsletter::Subscriber"
  }.freeze

  # A subscriber whose lifecycle marks the states the host reads (ADR 0097).
  MARKED_SUBSCRIBER_BODY = proc do
    instance_exec(&NEWSLETTER_SUBSCRIBER_BODY)
    lifecycle :status, default: "invited" do
      mark :awaiting_confirmation, "invited"
      mark :receives_issues, "active", "vip"
      mark :left, "gone"
      transition "Confirm"     => "active", from: "invited"
      transition "Promote"     => "vip",    from: "active"
      transition "Unsubscribe" => "gone",   from: %w[invited active vip]
    end
    command "Promote" do
      goal "promote"
      reference_to Subscriber
    end
  end

  NEWSLETTER_MARK_ROW = {
    awaiting_confirmation: "Subscriber.awaiting_confirmation",
    receives_issues:       "Subscriber.receives_issues",
    left:                  "Subscriber.left"
  }.freeze

  def newsletter_chapter(provides, body = NEWSLETTER_SUBSCRIBER_BODY)
    Hecks.bluebook "Newsletter" do
      vision "probe"
      supporting
      provides "newsletter", **provides
      aggregate "Subscriber", &body
    end
  end

  def registry_with_newsletter(provides: NEWSLETTER_VERBS, body: NEWSLETTER_SUBSCRIBER_BODY)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      newsletter_chapter(provides, body)
    end
    registry
  end

  it "resolves the chapter that provides newsletter, whatever it is named" do
    registry = registry_with_newsletter

    expect(registry.newsletter_provider_for("Newsletter").name).to eq("Newsletter")
  end

  it "exports the declared verbs qualified, with the subscribing aggregate named off subscribe" do
    exported = Hecks::Projector::Exporter.newsletter(registry_with_newsletter, "Newsletter")

    expect(exported).to eq(NEWSLETTER_EXPORT)
  end

  it "exports nothing for a domain that attaches no newsletter provider" do
    registry = Hecks::Runtime::Registry.new

    expect(Hecks::Projector::Exporter.newsletter(registry, "Pizzas")).to eq({})
  end

  it "refuses a provides row that leaves out a key the contract needs" do
    expect { registry_with_newsletter(provides: { subscribe: "Subscriber.Subscribe" }) }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /newsletter needs subscribe.*and may add awaiting_confirmation/)
  end

  it "refuses a provides row whose verb names no command the chapter declares" do
    expect { registry_with_newsletter(provides: NEWSLETTER_VERBS.merge(unsubscribe: "Subscriber.Leave")) }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /Subscriber\.Leave/)
  end

  context "with optional lifecycle marks" do
    let(:marked_row) { NEWSLETTER_VERBS.merge(NEWSLETTER_MARK_ROW) }

    it "exports the states of each lifecycle mark it names" do
      registry = registry_with_newsletter(provides: marked_row, body: MARKED_SUBSCRIBER_BODY)
      marks = { awaiting_confirmation: %w[invited], receives_issues: %w[active vip], left: %w[gone] }

      expect(Hecks::Projector::Exporter.newsletter(registry, "Newsletter")).to eq(NEWSLETTER_EXPORT.merge(marks))
    end

    it "leaves the export byte-identical to today when no mark is declared" do
      exported = Hecks::Projector::Exporter.newsletter(registry_with_newsletter(body: MARKED_SUBSCRIBER_BODY), "Newsletter")

      expect(exported).to eq(NEWSLETTER_EXPORT)
    end

    it "refuses a mark the aggregate's lifecycle does not declare" do
      row = NEWSLETTER_VERBS.merge(left: "Subscriber.departed")

      expect { registry_with_newsletter(provides: row, body: MARKED_SUBSCRIBER_BODY) }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /Subscriber\.departed.*no lifecycle mark/)
    end

    it "refuses a mark on an aggregate that has no lifecycle" do
      expect { registry_with_newsletter(provides: marked_row) }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /no lifecycle mark/)
    end
  end
end
