require "spec_helper"
require "tempfile"

# Real dispatch coverage for the `clamp` mutation op: bounds the current
# value into [min, max] -- no "amount" to combine, a genuinely different
# shape from multiply/increment/decrement (i106).
RSpec.describe "mutation op clamp" do
  def boot(source, hecksagon_name, &binds)
    file = Tempfile.new(["mutation-clamp-growth-", ".bluebook"])
    file.write(source)
    file.flush

    registry = Hecks::Runtime::Registry.new
    Hecks::Bluebook::MetaValidator.while_disabled do
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Kernel.eval(source, TOPLEVEL_BINDING, file.path, 1)
        Hecks.hecksagon(hecksagon_name, &binds)
      end
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(
      Hecks::Runtime::Dispatcher.new(registry)
    )
  ensure
    file&.close!
  end

  MUTATION_CLAMP_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "MutationClampGrowth" do
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

        # NO :strength ARGUMENT AT ALL — a genuinely phantom (never-set)
        # field, `Instance.defaults`'s own case for a VO-typed attribute
        # with no declared `default:`, unlike Open above which always
        # assigns one.
        command "OpenBare" do
          attribute :id, OrganId
          emits "OrganOpenedBare"
        end

        command "Bound" do
          reference_to Organ

          sets :strength, clamp: [0.0, 1.0]
          emits "OrganBounded"
        end
      end
    end
  BLUEBOOK

  def repository_for(runtime)
    aggregate = runtime.registry.bluebook("MutationClampGrowth").aggregate("Organ")
    runtime.registry.repository("MutationClampGrowth", aggregate)
  end

  def boot_mutation_clamp
    boot(MUTATION_CLAMP_SOURCE, "MutationClampGrowth") do
      MutationClampGrowth::Organ.persisted_by("Memory")
    end
  end

  it "bounds a value ABOVE the max down to the max" do
    runtime = boot_mutation_clamp
    runtime.dispatch("MutationClampGrowth::Organ.Open", id: { value: "o1" }, strength: { value: 1.4 })
    runtime.dispatch("MutationClampGrowth::Organ.Bound", id: "o1")

    organ = repository_for(runtime).find("o1")
    expect(organ[:strength][:value]).to eq(1.0)
  end

  it "bounds a value BELOW the min up to the min" do
    runtime = boot_mutation_clamp
    runtime.dispatch("MutationClampGrowth::Organ.Open", id: { value: "o2" }, strength: { value: -0.3 })
    runtime.dispatch("MutationClampGrowth::Organ.Bound", id: "o2")

    organ = repository_for(runtime).find("o2")
    expect(organ[:strength][:value]).to eq(0.0)
  end

  it "leaves an in-range value untouched" do
    runtime = boot_mutation_clamp
    runtime.dispatch("MutationClampGrowth::Organ.Open", id: { value: "o3" }, strength: { value: 0.42 })
    runtime.dispatch("MutationClampGrowth::Organ.Bound", id: "o3")

    organ = repository_for(runtime).find("o3")
    expect(organ[:strength][:value]).to eq(0.42)
  end

  # THE PHANTOM-FIELD FIX (docs/fuzzer-property-expansion-plan.md
  # summary, item 4): #arithmetic/#multiply both give a never-set
  # numeric field `current ||= 0` — #clamp didn't, so it hit TypeMismatch
  # on the FIRST clamp of a field OpenBare never assigned, where
  # increment/decrement/multiply would have silently treated the same
  # absence as zero. Clamping 0.0 into [0.0, 1.0] leaves it at the
  # bottom of the range, untouched — the same "in range" outcome the
  # previous example proves for an explicitly-set 0.42.
  it "treats a phantom (never-set) numeric field as zero rather than refusing TypeMismatch" do
    runtime = boot_mutation_clamp
    runtime.dispatch("MutationClampGrowth::Organ.OpenBare", id: { value: "o4" })

    expect { runtime.dispatch("MutationClampGrowth::Organ.Bound", id: "o4") }.not_to raise_error

    organ = repository_for(runtime).find("o4")
    expect(organ[:strength][:value]).to eq(0.0)
  end
end
