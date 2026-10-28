require "spec_helper"

# Memory is the default store. A hecksagon that wires no persistence leaves its aggregates
# there; one that wires some and forgets one is refused; a root `persisted_by` reaches the
# chapters it attaches.
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

  it "hands an attaching domain's root default to the chapter it attaches" do
    wire { subscribes_to "Elsewhere" }
    attach_with_default("PostgresEra")
    expect(adapter_of("Bubble")).to eq("PostgresEra")
  end

  it "keeps an aggregate's own bind over the inherited default" do
    wire { Deciderate::Game.persisted_by("Memory") }
    attach_with_default("PostgresEra")
    expect(adapter_of("Game")).to eq("Memory")
  end
end
