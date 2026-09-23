require "spec_helper"

# 2.0: `uses_framework` / `uses_embryonaut_bluebook` load bounded contexts
# (module wrap, no Object shortcut). A consumer chapter can also write
# `bounded` itself. An explicit `bounded` mark always needs a `translates`
# ACL or boot refuses. Attaching a BC without its sibling hecksagon
# refuses too — that sibling is the anti-corruption layer.
RSpec.describe "bounded contexts" do
  def registry_with(&block)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      block.call
    end
    registry
  end

  def declare_echo
    Hecks.bluebook "BoundedEcho" do
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
  end

  def declare_thing
    Hecks.bluebook "BoundedThing" do
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
  end

  def declare_probe
    Hecks.bluebook "Probe" do
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
  end

  it "marks a uses_framework member bounded without writing bounded in that bluebook" do
    registry = registry_with do
      declare_probe
      Hecks.hecksagon "Probe" do
        uses_framework "Governance"
        Probe::Widget.persisted_by("Memory")
      end
      sibling_governance!
    end

    expect(registry.bounded?("Governance")).to be true
    expect(registry.bounded?("Probe")).to be false
    expect { registry.verify! }.not_to raise_error
  end

  it "refuses boot when uses_framework has no sibling hecksagon" do
    registry = registry_with do
      declare_probe
      Hecks.hecksagon "Probe" do
        uses_framework "Governance"
        Probe::Widget.persisted_by("Memory")
      end
    end

    expect { registry.verify! }
      .to raise_error(Hecks::Runtime::WiringError, /bounded context.*Governance/)
  end

  it "refuses boot when a consumer chapter is marked bounded with no translates ACL" do
    registry = registry_with do
      declare_echo
      Hecks.hecksagon "BoundedEcho" do
        bounded
        BoundedEcho::Echo.persisted_by("Memory")
      end
    end

    expect(registry.hecksagon("BoundedEcho").bounded?).to be true
    expect { registry.verify! }
      .to raise_error(Hecks::Runtime::WiringError, /marked bounded but never declared a translates ACL/)
  end

  it "boots a bounded consumer chapter that declares a translates ACL" do
    registry = registry_with do
      declare_thing
      declare_echo
      Hecks.hecksagon "BoundedThing" do
        BoundedThing::Thing.persisted_by("Memory")
      end
      Hecks.hecksagon "BoundedEcho" do
        bounded
        BoundedEcho::Echo.persisted_by("Memory")
        translates "EchoOnThingFired" do
          on Thing::ThingFired
          trigger Echo::Register
        end
      end
    end

    expect { registry.verify! }.not_to raise_error
    expect(registry.hecksagon("BoundedEcho").translates).to eq(["EchoOnThingFired"])
    expect(registry.bounded?("BoundedEcho")).to be true
  end

  # Two full boots (opposite load order) is the whole claim; splitting
  # would re-pay declare_echo/declare_thing without proving more.
  # rubocop:disable-next RSpec/ExampleLength
  it "merges same-name hecksagon blocks order-independently" do
    first = registry_with do
      declare_echo
      Hecks.hecksagon "BoundedEcho" do
        uses_framework "Governance"
        BoundedEcho::Echo.persisted_by("Memory")
      end
      Hecks.hecksagon "Governance" do
        Governance::RoleAssignment.persisted_by("Memory")
      end
      Hecks.hecksagon "BoundedEcho" do
        bounded
        translates "EchoOnThingFired" do
          on Thing::ThingFired
          trigger Echo::Register
        end
      end
      declare_thing
      Hecks.hecksagon "BoundedThing" do
        BoundedThing::Thing.persisted_by("Memory")
      end
    end

    second = registry_with do
      declare_thing
      declare_echo
      Hecks.hecksagon "BoundedEcho" do
        bounded
        translates "EchoOnThingFired" do
          on Thing::ThingFired
          trigger Echo::Register
        end
      end
      Hecks.hecksagon "Governance" do
        Governance::RoleAssignment.persisted_by("Memory")
      end
      Hecks.hecksagon "BoundedEcho" do
        uses_framework "Governance"
        BoundedEcho::Echo.persisted_by("Memory")
      end
      Hecks.hecksagon "BoundedThing" do
        BoundedThing::Thing.persisted_by("Memory")
      end
    end

    [first, second].each do |registry|
      expect { registry.verify! }.not_to raise_error
      hexagon = registry.hecksagon("BoundedEcho")
      expect(hexagon.bounded?).to be true
      expect(hexagon.framework_members).to eq(["Governance"])
      expect(hexagon.translates).to eq(["EchoOnThingFired"])
    end
  end
end
