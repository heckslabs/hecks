require "spec_helper"
require_relative "../../support/memory_ports"

# A capability the language defines no contract for belongs to the package that provides it: each
# `provides` key must name one thing the bluebook declares, and `ir.json`'s `provides` map hands the
# reader what that thing resolves to. The reader checks the keys it needs.
RSpec.describe "package-declared capability" do
  let(:full_row) do
    { fire: "Kiln.Fire", cooled: "Kiln.Thermometer.Cooled", busy: "Kiln.busy", hold: "Kiln.hold",
      batch_at: "Kiln.batch_at" }
  end

  let(:full_export) do
    { provider: "Workshop", fire: "Workshop::Kiln.Fire", cooled: "Workshop::Kiln.Thermometer.Cooled",
      busy: %w[firing], hold: { attribute: "hold", default: 1800 }, batch_at: { attribute: "batch_at", default: nil } }
  end

  KILN_BODY = proc do
    identified_by :code
    attribute :code, Code
    value_object "Code", String
    value_object "Seconds", Integer
    attribute :hold, Seconds, default: { value: 1800 }
    attribute :batch_at, Code, optional: true
    command("Fire") do
      goal "fire"
      attribute :code, Code
      sets :code
    end
    command("Rest") do
      goal "rest"
      reference_to Kiln
    end
    lifecycle :status, default: "idle" do
      mark :busy, "firing"
      transition "Fire" => "firing", from: "idle"
      transition "Rest" => "idle", from: "firing"
    end
  end

  # A kiln that also declares an attribute named like its lifecycle mark.
  AMBIGUOUS_KILN_BODY = proc do
    instance_exec(&KILN_BODY)
    attribute :busy, Code, optional: true
  end

  def workshop_bluebook(capability, provides, body)
    Hecks.bluebook "Workshop" do
      vision "probe"
      supporting
      provides capability, **provides
      aggregate "Kiln", &body
    end
  end

  def workshop_hecksagon(operations)
    Hecks.hecksagon("Workshop") do
      Workshop::Kiln.persisted_by("Memory")
      Workshop::Kiln.port("Thermometer") do
        operations.each { |name| operation(name) { emits "Kiln#{name}" } }
      end
    end
  end

  def registry_with(provides: full_row, operations: %w[Cooled], capability: "glazing", body: KILN_BODY)
    Hecks::Runtime::Registry.new.tap do |registry|
      Hecks.with_registry(registry) do
        MemoryPorts.load!
        workshop_bluebook(capability, provides, body)
        workshop_hecksagon(operations)
      end
    end
  end

  it "resolves the bluebook that provides it through the generic lookup" do
    expect(registry_with.vendored_provider_for("Workshop", "glazing").name).to eq("Workshop")
  end

  it "exports each key as what its target resolves to" do
    expect(Hecks::Projector::Exporter.provides(registry_with, "Workshop")).to eq("glazing" => full_export)
  end

  it "exports nothing when no loaded bluebook declares a package capability" do
    expect(Hecks::Projector::Exporter.provides(Hecks::Runtime::Registry.new, "Pizzas")).to eq({})
  end

  it "boots when the hecksagon declares the port operation a key names" do
    expect { registry_with.verify! }.not_to raise_error
  end

  it "refuses at verify! when the hecksagon lacks the port operation a key names" do
    expect { registry_with(operations: %w[Heated]).verify! }
      .to raise_error(Hecks::Runtime::WiringError, /Workshop provides "glazing" cooled.*no such port operation/)
  end

  it "refuses a key that names nothing the bluebook declares" do
    expect { registry_with(provides: full_row.merge(fire: "Kiln.Ignite")) }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /glazing" fire: "Kiln\.Ignite", which names nothing/)
  end

  it "refuses a key whose target names two kinds at once" do
    expect { registry_with(provides: { busy: "Kiln.busy" }, body: AMBIGUOUS_KILN_BODY) }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /names mark and attribute at once/)
  end

  it "still holds a capability the language defines to its contract" do
    expect { registry_with(capability: "privacy", provides: { mark_sensitive: "Kiln.Fire" }) }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /privacy needs exactly mark_sensitive, markings_for/)
  end
end
