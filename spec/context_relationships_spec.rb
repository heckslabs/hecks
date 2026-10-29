require "spec_helper"
require "hecks/bluebook/model_check"

# The context map is read off what each context already declares; nothing is written for it.
RSpec.describe Hecks::Projections::ContextRelationships do
  DECLARE_REL_CONTEXT = lambda do |name, aggregate, fact|
    Hecks.bluebook name do
      aggregate aggregate do
        identified_by :id
        attribute :id, Id

        value_object "Id" do
          attribute :value, String
          invariant("an id is present") { !value.to_s.empty? }
        end

        command "Fire" do
          goal "emit a fact"
          attribute :id, Id
          sets :id
          emits fact
        end
      end
    end
  end

  # A policy marked `across` is a customer/supplier relationship with the named context.
  DECLARE_REL_ORDERS = lambda do
    Hecks.bluebook "RelOrders" do
      aggregate "Order" do
        identified_by :id
        attribute :id, Id

        value_object "Id" do
          attribute :value, String
          invariant("an id is present") { !value.to_s.empty? }
        end

        command "Place" do
          goal "place an order"
          attribute :id, Id
          sets :id
          emits "OrderPlaced"
        end
      end

      policy "ShipOnPlaced" do
        on      Order::OrderPlaced
        trigger Shipment::Dispatch
        across  "RelUpstream"
      end
    end
  end

  WIRE_REL_LOCAL = lambda do
    Hecks.hecksagon "RelLocal" do
      attaches "Governance"
      subscribe "RelAudit.Logged"
      RelLocal::Echo.persisted_by("Memory")
      translates("EchoOnThingFired") do
        on Thing::ThingFired
        trigger Echo::Fire
      end
    end
  end

  # RelDecoy names its aggregate as RelUpstream does, but emits a different event.
  def declare_contexts
    DECLARE_REL_CONTEXT.call("RelDecoy", "Thing", "ThingKept")
    DECLARE_REL_CONTEXT.call("RelUpstream", "Thing", "ThingFired")
    DECLARE_REL_CONTEXT.call("RelLocal", "Echo", "EchoFired")
  end

  def registry
    @registry ||= Hecks::Runtime::Registry.new.tap do |registry|
      Hecks.with_registry(registry) do
        MemoryPorts.load!
        declare_contexts
        DECLARE_REL_ORDERS.call
        Hecks.hecksagon("RelUpstream") { RelUpstream::Thing.persisted_by("Memory") }
        WIRE_REL_LOCAL.call
      end
    end
  end

  def edges = described_class.call(registry: registry)

  it "reads an attaches as a shared kernel" do
    expect(edges).to include(from: "RelLocal", to: "Governance", kind: "shared_kernel", via: nil)
  end

  it "reads an attaches of the context's own vendored package as no relationship" do
    attachments = %w[RelLocal Governance].map { |name| Struct.new(:declaration_name).new(name) }
    wired = Struct.new(:domain, :attachments).new("RelLocal", attachments)

    expect(described_class.attach_edges(wired).map(&:to)).to eq(["Governance"])
  end

  it "reads a hecksagon translates as an anti-corruption layer onto the context that owns the event" do
    expect(edges).to include(from: "RelLocal", to: "RelUpstream", kind: "acl", via: "EchoOnThingFired")
  end

  it "takes the context whose aggregate emits the event when another declares the same aggregate name" do
    expect(edges.map { |edge| edge[:to] }).not_to include("RelDecoy")
  end

  it "reads a policy marked across as customer/supplier, named for the policy" do
    expect(edges).to include(from: "RelOrders", to: "RelUpstream", kind: "customer_supplier", via: "ShipOnPlaced")
  end

  it "reads a subscribe with nothing stronger behind it as a subscription" do
    expect(edges).to include(from: "RelLocal", to: "RelAudit", kind: "subscription", via: "RelAudit.Logged")
  end

  it "drops a subscription that a stronger edge to the same context already explains" do
    Hecks.with_registry(registry) { Hecks.hecksagon("RelLocal") { subscribe "RelUpstream.ThingFired" } }

    expect(edges.map { |edge| [edge[:to], edge[:kind]] }).not_to include(%w[RelUpstream subscription])
  end

  it "renders one line per edge" do
    expect(described_class.text(registry: registry)).to include("RelLocal --acl--> RelUpstream (EchoOnThingFired)")
  end
end
