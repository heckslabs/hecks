require "spec_helper"

# 2.0: `attaches` / `attaches ... from: :vendor` load bounded contexts
# (module wrap, no Object shortcut). A consumer chapter can also write
# `bounded` itself. An explicit `bounded` mark always needs a `translates`
# ACL or boot refuses. Attaching a BC without its sibling hecksagon
# refuses too — that sibling is the anti-corruption layer.
RSpec.describe "bounded contexts" do
  def registry_with(&)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      yield
    end
    registry
  end

  BOUNDED_ECHO_BLUEBOOK = proc do
    aggregate "Echo" do
      identified_by :id
      attribute :id, Id

      value_object "Id" do
        attribute :value, String
        invariant("an id is present") { !value.to_s.empty? }
      end

      command "Register" do
        goal "record the echo"
        attribute :id, Id
        sets :id
        emits "EchoRegistered"
      end
    end
  end

  BOUNDED_THING_BLUEBOOK = proc do
    aggregate "Thing" do
      identified_by :id
      attribute :id, Id

      value_object "Id" do
        attribute :value, String
        invariant("an id is present") { !value.to_s.empty? }
      end

      command "Fire" do
        goal "emit a fact another domain reacts to"
        attribute :id, Id
        sets :id
        emits "ThingFired"
      end
    end
  end

  BOUNDED_PROBE_BLUEBOOK = proc do
    aggregate "Widget" do
      identified_by :id
      attribute :id, Id
      value_object "Id" do
        attribute :value, String
        invariant("an id is present") { !value.to_s.empty? }
      end
      command "Make" do
        goal "make"
        attribute :id, Id
        sets :id
        emits "Made"
      end
    end
  end

  def declare_echo = Hecks.bluebook("BoundedEcho", &BOUNDED_ECHO_BLUEBOOK)

  def declare_thing = Hecks.bluebook("BoundedThing", &BOUNDED_THING_BLUEBOOK)

  def declare_probe = Hecks.bluebook("Probe", &BOUNDED_PROBE_BLUEBOOK)

  def probe_hexagon
    Hecks.hecksagon "Probe" do
      attaches "Governance"
      Probe::Widget.persisted_by("Memory")
    end
  end

  def thing_hexagon
    Hecks.hecksagon "BoundedThing" do
      BoundedThing::Thing.persisted_by("Memory")
    end
  end

  def governance_hexagon
    Hecks.hecksagon "Governance" do
      Governance::RoleAssignment.persisted_by("Memory")
    end
  end

  def echo_attached_hexagon
    Hecks.hecksagon "BoundedEcho" do
      attaches "Governance"
      BoundedEcho::Echo.persisted_by("Memory")
    end
  end

  def echo_bounded_hexagon
    Hecks.hecksagon "BoundedEcho" do
      bounded
      BoundedEcho::Echo.persisted_by("Memory")
    end
  end

  def echo_translating_hexagon(persisted: false)
    Hecks.hecksagon "BoundedEcho" do
      bounded
      BoundedEcho::Echo.persisted_by("Memory") if persisted
      translates "EchoOnThingFired" do
        on Thing::ThingFired
        trigger Echo::Register
      end
    end
  end

  def probe_registry(sibling: true)
    registry_with do
      declare_probe
      probe_hexagon
      sibling_governance! if sibling
    end
  end

  def translating_registry
    registry_with do
      declare_thing
      declare_echo
      thing_hexagon
      echo_translating_hexagon(persisted: true)
    end
  end

  # A booted registry whose declarations ran in the order given, by method name.
  def registry_declaring(order)
    registry_with do
      order.each { |declaration| send(declaration) }
    end
  end

  BOUNDED_MERGE_FORWARD = [:declare_echo, :echo_attached_hexagon, :governance_hexagon, :echo_translating_hexagon,
                           :declare_thing, :thing_hexagon].freeze
  BOUNDED_MERGE_REVERSED = [:declare_thing, :declare_echo, :echo_translating_hexagon, :governance_hexagon,
                            :echo_attached_hexagon, :thing_hexagon].freeze

  def expect_merged(registry)
    expect { registry.verify! }.not_to raise_error
    expect_merged_hexagon(registry.hecksagon("BoundedEcho"))
  end

  def expect_merged_hexagon(hecksagon)
    expect(hecksagon.bounded?).to be true
    expect(hecksagon.member_chapters).to eq(["Governance"])
    expect(hecksagon.translates).to eq(["EchoOnThingFired"])
  end

  it "marks an attached member bounded without writing bounded in that bluebook", :aggregate_failures do
    registry = probe_registry

    expect(registry.bounded?("Governance")).to be true
    expect(registry.bounded?("Probe")).to be false
    expect { registry.verify! }.not_to raise_error
  end

  it "refuses boot when an attachment has no sibling hecksagon" do
    registry = probe_registry(sibling: false)

    expect { registry.verify! }
      .to raise_error(Hecks::Runtime::WiringError, /bounded context.*Governance/)
  end

  it "refuses boot when a consumer chapter is marked bounded with no translates ACL", :aggregate_failures do
    registry = registry_declaring([:declare_echo, :echo_bounded_hexagon])

    expect(registry.hecksagon("BoundedEcho").bounded?).to be true
    expect { registry.verify! }
      .to raise_error(Hecks::Runtime::WiringError, /marked bounded but never declared a translates ACL/)
  end

  it "boots a bounded consumer chapter that declares a translates ACL", :aggregate_failures do
    registry = translating_registry

    expect { registry.verify! }.not_to raise_error
    expect(registry.hecksagon("BoundedEcho").translates).to eq(["EchoOnThingFired"])
    expect(registry.bounded?("BoundedEcho")).to be true
  end

  it "merges same-name hecksagon blocks order-independently", :aggregate_failures do
    [BOUNDED_MERGE_FORWARD, BOUNDED_MERGE_REVERSED].each { |order| expect_merged(registry_declaring(order)) }
  end
end
