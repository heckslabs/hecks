require "spec_helper"

# `translates` in a hecksagon builds the same Policy a bluebook `policy` block would.
RSpec.describe "translates, a hecksagon-level cross-domain reaction" do
  def declare_foreign
    Hecks.bluebook "TranslatesForeign" do
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

  def declare_local
    Hecks.bluebook "TranslatesLocal" do
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

  def wire_hecksagons
    Hecks.hecksagon "TranslatesForeign" do
      TranslatesForeign::Thing.persisted_by("Memory")
    end

    Hecks.hecksagon "TranslatesLocal" do
      TranslatesLocal::Echo.persisted_by("Memory")

      # Reacts to a foreign domain's event without touching TranslatesLocal's bluebook.
      translates "EchoOnThingFired" do
        on Thing::ThingFired
        trigger Echo::Register
      end
    end
  end

  def boot
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)

      declare_foreign
      declare_local
      wire_hecksagons
    end

    registry.verify!
    [Hecks::Runtime::Dispatcher.new(registry), registry]
  end

  it "builds a real Policy attached to the named chapter" do
    _dispatcher, registry = boot

    policy = registry.bluebook("TranslatesLocal").policies.find { |p| p.name == "EchoOnThingFired" }

    expect(policy).not_to be_nil
    expect(policy.on_event).to eq("Thing.ThingFired")
    expect(policy.trigger_command).to eq("Echo.Register")
  end

  it "fires for real: a foreign command's event triggers the local command" do
    dispatcher, registry = boot

    dispatcher.dispatch("TranslatesForeign::Thing.Fire", to: "x1", with: { id: { value: "x1" } })

    echo = registry.repository("TranslatesLocal", registry.bluebook("TranslatesLocal").aggregate("Echo")).find("x1")

    expect(echo).not_to be_nil
    expect(registry.reaction_log.last[:delivered]).to be(true)
  end

  it "omits the domain prefix on purpose — a domain-qualified on would never match" do
    dispatcher, registry = boot
    dispatcher.dispatch("TranslatesForeign::Thing.Fire", to: "x2", with: { id: { value: "x2" } })

    policy = registry.bluebook("TranslatesLocal").policies.find { |p| p.name == "EchoOnThingFired" }

    # `on` omits the domain prefix: Naming.qualifier of a 3-segment name yields
    # "Domain::Aggregate", which never matches PolicyInterpreter's demodulised comparison.
    expect(policy.event_qualifier).to eq("Thing")
  end
end
