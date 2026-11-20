require "spec_helper"

# An event committed is owed to each consumer until the consumer has answered it. The bluebook
# holds the promise; the runtime reaches it through the `event_delivery` capability.
RSpec.describe "event delivery" do
  let(:hecks) { Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/framework"), install_driving: false) }
  let(:id) { { delivery_id: { value: "e1/policy:Pizzas::Bake" } } }

  def enqueue
    hecks.dispatch_flat("EventDelivery::Delivery.Enqueue", **id, event_id: { value: "e1" }, domain: { value: "Pizzas" },
                                                           consumer: { value: "policy:Pizzas::Bake" },
                                                           kind: { value: "reaction" })
  end

  def step(*verbs, **extra) = verbs.each { |verb| hecks.dispatch_flat("EventDelivery::Delivery.#{verb}", **id, **extra) }

  def status = hecks.query("EventDelivery::Delivery.All").first[:status]

  # Enqueued, claimed, failed, redriven, claimed again and delivered.
  def walk_a_delivery_through_a_redrive
    enqueue
    step("Claim")
    step("Fail", error: { value: "boom" })
    step("Redrive", "Claim", "Deliver")
  end

  it "delivers an event once its failed delivery is redriven" do
    walk_a_delivery_through_a_redrive

    expect(status).to eq("delivered")
  end

  it "is the framework member that provides event delivery" do
    expect(Hecks::Framework.providers_of("event_delivery")).to eq(["EventDelivery"])
  end
end
