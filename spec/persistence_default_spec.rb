require "spec_helper"

# Memory is the default store. A hecksagon that wires no persistence leaves its aggregates
# there; one that wires some and forgets one is refused; a root `persisted_by` reaches the
# bluebooks it attaches.
RSpec.describe Hecks::Ports::Persistence::BindingPolicy do
  let(:registry) { Hecks::Runtime::Registry.new }
  let(:fixture) { File.expand_path("fixtures/deciderate.bluebook", __dir__) }

  def wire(&block)
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      Kernel.load(fixture)
      Hecks.hecksagon("Deciderate", &block)
    end
  end

  def adapter_of(aggregate_name)
    aggregate = registry.bluebook("Deciderate").aggregate(aggregate_name)
    described_class.resolve(registry, "Deciderate", aggregate).adapter
  end

  # A host hecksagon attaching Deciderate, with a root `persisted_by` of `adapter`.
  def attach_with_default(adapter)
    attachment = Hecks::Bluebook::Attachment.new(name: "Deciderate", source: :gem)
    bind = Hecks::Bluebook::Bind.new(aggregate: nil, verb: "persisted_by", adapter: adapter, role: nil)
    registry.hecksagons["Host"] = Hecks::Bluebook::Hecksagon.new(domain: "Host", binds: [bind], attachments: [attachment])
  end

  it "leaves a hecksagon that wires no persistence in Memory" do
    wire { subscribes_to "Elsewhere" }
    expect(adapter_of("Game")).to eq("Memory")
  end

  it "refuses an aggregate left out when the hecksagon binds another" do
    wire { Deciderate::Game.persisted_by("Heki") }
    expect { adapter_of("Bubble") }.to raise_error(Hecks::Runtime::WiringError, /forgotten decision/)
  end

  it "hands an attaching domain's root default to the bluebook it attaches" do
    wire { subscribes_to "Elsewhere" }
    attach_with_default("Postgres")
    expect(adapter_of("Bubble")).to eq("Postgres")
  end

  it "keeps an aggregate's own bind over the inherited default" do
    wire { Deciderate::Game.persisted_by("Memory") }
    attach_with_default("Postgres")
    expect(adapter_of("Game")).to eq("Memory")
  end

  # A host hecksagon named `name` attaching Deciderate, handing down Postgres, with `revisions`.
  def attach_as(name, revisions:)
    attachment = Hecks::Bluebook::Attachment.new(name: "Deciderate", source: :gem)
    bind = Hecks::Bluebook::Bind.new(aggregate: nil, verb: "persisted_by", adapter: "Postgres", role: nil)
    registry.hecksagons[name] = Hecks::Bluebook::Hecksagon.new(
      domain: name, binds: [bind], attachments: [attachment], revisions: revisions
    )
  end

  it "hands an attaching domain's `revisions true` to the bluebook it attaches" do
    wire { subscribes_to "Elsewhere" }
    attach_as("Host", revisions: true)
    expect(described_class.revisions?(registry, "Deciderate")).to be(true)
  end

  it "does not hand revisions down when the attaching domain keeps the plain layout" do
    wire { subscribes_to "Elsewhere" }
    attach_as("Host", revisions: false)
    expect(described_class.revisions?(registry, "Deciderate")).to be(false)
  end

  it "keeps a bluebook with its own persisted_by out of the root's revisions" do
    wire { Deciderate::Game.persisted_by("Heki") }
    attach_as("Host", revisions: true)
    expect(described_class.revisions?(registry, "Deciderate")).to be(false)
  end

  it "refuses attaching domains that disagree on revisions" do
    wire { subscribes_to "Elsewhere" }
    attach_as("Host", revisions: true)
    attach_as("Other", revisions: false)
    expect { described_class.revisions?(registry, "Deciderate") }
      .to raise_error(Hecks::Runtime::WiringError, /disagree on revisions.*Host: true, Other: false/)
  end
end
