require "spec_helper"

# A saga correlated by a bare value-object identity keys its instances by the identity's scalar,
# the same key a dotted `.value` path gives. The raised event carries the identity as a value
# object, so the runtime reads that object's one field before it compares.
RSpec.describe "a saga correlated by a value-object identity" do
  def raise_command
    proc do
      command "Raise" do
        attribute :code, SightingCode
        emits "SightingRaised"
      end
    end
  end

  def sighting_aggregate
    raise_sighting_command = raise_command
    proc do
      aggregate "Sighting" do
        identified_by :code
        attribute :code, SightingCode
        value_object("SightingCode") { attribute :value, String }
        instance_eval(&raise_sighting_command)
      end
    end
  end

  def bare_key_process_manager
    proc do
      process_manager "BareKey" do
        correlates_by Sighting
        starts_on "SightingRaised"
        transition("SightingRaised" => "watching", from: "watching")
      end
    end
  end

  def dotted_key_process_manager
    proc do
      process_manager "DottedKey" do
        correlates_by :"code.value"
        starts_on "SightingRaised"
        transition("SightingRaised" => "watching", from: "watching")
      end
    end
  end

  def sighting_domain
    parts = [sighting_aggregate, bare_key_process_manager, dotted_key_process_manager]
    proc { parts.each { |part| instance_eval(&part) } }
  end

  def boot_sightings
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      MemoryPorts.load!
      Hecks.bluebook("Sightings", version: "v1", &sighting_domain)
      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    end
  end

  let(:runtime) { boot_sightings }

  def raise_sighting(code)
    runtime.dispatch_flat("Sightings::Sighting.Raise", code: { value: code })
  end

  def instances_of(process_manager)
    runtime.registry.saga_instances[process_manager].keys
  end

  before { raise_sighting("smoke-1") }

  it "keys a bare value-object identity by its scalar" do
    expect(instances_of("BareKey")).to eq(["smoke-1"])
  end

  it "keys a dotted `.value` path by the same scalar" do
    expect(instances_of("DottedKey")).to eq(["smoke-1"])
  end

  it "opens one instance per identity, not one per event" do
    raise_sighting("smoke-2")

    expect(instances_of("BareKey")).to eq(["smoke-1", "smoke-2"])
  end
end
