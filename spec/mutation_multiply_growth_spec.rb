require "spec_helper"
require "tempfile"

# Real dispatch coverage for the `multiply` mutation op: `current * amount`,
# the scaling counterpart to increment/decrement's add/subtract (i106).
RSpec.describe "mutation op multiply" do
  def boot(source, hecksagon_name, &binds)
    file = Tempfile.new(["mutation-multiply-growth-", ".bluebook"])
    file.write(source)
    file.flush

    previous = ENV["HECKS_META_VALIDATION"]
    ENV["HECKS_META_VALIDATION"] = "off"

    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.eval(source, TOPLEVEL_BINDING, file.path, 1)
      Hecks.hecksagon(hecksagon_name, &binds)
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(
      Hecks::Runtime::Dispatcher.new(registry)
    )
  ensure
    ENV["HECKS_META_VALIDATION"] = previous
    file&.close!
  end

  MUTATION_MULTIPLY_SOURCE = <<~BLUEBOOK
    Hecks.bluebook "MutationMultiplyGrowth" do
      aggregate "Organ" do
        identified_by :id

        value_object "OrganId" do
          attribute :value, String
        end

        value_object "Strength" do
          attribute :value, Float
        end

        attribute :id,       OrganId
        attribute :strength, Strength

        command "Open" do
          attribute :id, OrganId
          attribute :strength, Strength
          emits "OrganOpened"
        end

        command "Decay" do
          reference_to Organ
          attribute :factor, Strength

          sets :strength, multiply: :factor
          emits "OrganDecayed"
        end
      end
    end
  BLUEBOOK

  def repository_for(runtime)
    aggregate = runtime.registry.bluebook("MutationMultiplyGrowth").aggregate("Organ")
    runtime.registry.repository("MutationMultiplyGrowth", aggregate)
  end

  def boot_mutation_multiply
    boot(MUTATION_MULTIPLY_SOURCE, "MutationMultiplyGrowth") do
      ::MutationMultiplyGrowth::Organ.persisted_by("Memory")
    end
  end

  it "scales a value-object field by the given factor" do
    runtime = boot_mutation_multiply
    runtime.dispatch("MutationMultiplyGrowth::Organ.Open", id: { value: "o1" }, strength: { value: 1.0 })
    runtime.dispatch("MutationMultiplyGrowth::Organ.Decay", id: "o1", factor: { value: 0.98 })

    organ = repository_for(runtime).find("o1")
    expect(organ[:strength][:value]).to be_within(0.0001).of(0.98)
  end

  it "raises a TypeMismatch scaling a non-numeric current value" do
    runtime = boot_mutation_multiply
    runtime.dispatch("MutationMultiplyGrowth::Organ.Open", id: { value: "o2" }, strength: { value: 1.0 })

    expect do
      runtime.dispatch("MutationMultiplyGrowth::Organ.Decay", id: "o2", factor: "not-a-number")
    end.to raise_error(Hecks::Runtime::TypeMismatch)
  end
end
