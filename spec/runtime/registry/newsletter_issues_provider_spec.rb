require "spec_helper"
require_relative "../../support/memory_ports"

# rust/host's issue-send route reads ir.json's `newsletter_issues` key instead
# of naming Newsletter::Issue.Send and Newsletter::Delivery.Record. That key is
# only as trustworthy as the `provides "newsletter_issues"` row behind it, so
# the row is held to its contract (every key, each naming a real command) and
# the exporter answers nothing for a domain that attaches no such chapter.
RSpec.describe "newsletter_issues capability" do
  NEWSLETTER_ISSUES_ISSUE_BODY = proc do
    identified_by :slug
    attribute :slug, Slug
    value_object "Slug" do
      attribute :value, String
    end
    command "Draft" do
      goal "draft"
      attribute :slug, Slug
      sets :slug
    end
    command "Send" do
      goal "send"
      reference_to Issue
    end
  end

  NEWSLETTER_ISSUES_DELIVERY_BODY = proc do
    identified_by :delivery_id
    attribute :delivery_id, DeliveryId
    value_object "DeliveryId" do
      attribute :value, String
    end
    command "Record" do
      goal "record"
      attribute :delivery_id, DeliveryId
      sets :delivery_id
    end
  end

  NEWSLETTER_ISSUES_EXPORT = {
    provider:           "Newsletter",
    send_issue:         "Newsletter::Issue.Send",
    record_delivery:    "Newsletter::Delivery.Record",
    issue_aggregate:    "Newsletter::Issue",
    delivery_aggregate: "Newsletter::Delivery"
  }.freeze

  def newsletter_chapter(provides)
    Hecks.bluebook "Newsletter" do
      vision "probe"
      supporting
      provides "newsletter_issues", **provides
      aggregate "Issue", &NEWSLETTER_ISSUES_ISSUE_BODY
      aggregate "Delivery", &NEWSLETTER_ISSUES_DELIVERY_BODY
    end
  end

  def registry_with_issues(provides: { send_issue: "Issue.Send", record_delivery: "Delivery.Record" })
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      newsletter_chapter(provides)
    end
    registry
  end

  it "resolves the chapter that provides newsletter_issues, whatever it is named" do
    registry = registry_with_issues

    expect(registry.newsletter_issues_provider_for("Newsletter").name).to eq("Newsletter")
  end

  it "exports the declared verbs qualified, with the issue and delivery aggregates named off them" do
    exported = Hecks::Projector::Exporter.newsletter_issues(registry_with_issues, "Newsletter")

    expect(exported).to eq(NEWSLETTER_ISSUES_EXPORT)
  end

  it "exports nothing for a domain that attaches no issue-sending provider" do
    registry = Hecks::Runtime::Registry.new

    expect(Hecks::Projector::Exporter.newsletter_issues(registry, "Pizzas")).to eq({})
  end

  it "refuses a provides row that leaves out a key the contract needs" do
    expect { registry_with_issues(provides: { send_issue: "Issue.Send" }) }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /newsletter_issues needs exactly/)
  end

  it "refuses a provides row whose verb names no command the chapter declares" do
    expect { registry_with_issues(provides: { send_issue: "Issue.Send", record_delivery: "Delivery.Log" }) }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /Delivery\.Log/)
  end
end
