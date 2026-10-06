require "spec_helper"
require_relative "support/inline_bluebook_boot"

# Real dispatch coverage for the `clamp` mutation op: bounds the current value into
# [min, max], with no "amount" to combine.
RSpec.describe "mutation op clamp" do
  include InlineBluebookBoot

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
    runtime.dispatch_flat("MutationClampGrowth::Organ.Open", id: { value: "o1" }, strength: { value: 1.4 })
    runtime.dispatch_flat("MutationClampGrowth::Organ.Bound", id: "o1")

    organ = repository_for(runtime).find("o1")
    expect(organ[:strength][:value]).to eq(1.0)
  end

  it "bounds a value BELOW the min up to the min" do
    runtime = boot_mutation_clamp
    runtime.dispatch_flat("MutationClampGrowth::Organ.Open", id: { value: "o2" }, strength: { value: -0.3 })
    runtime.dispatch_flat("MutationClampGrowth::Organ.Bound", id: "o2")

    organ = repository_for(runtime).find("o2")
    expect(organ[:strength][:value]).to eq(0.0)
  end

  it "leaves an in-range value untouched" do
    runtime = boot_mutation_clamp
    runtime.dispatch_flat("MutationClampGrowth::Organ.Open", id: { value: "o3" }, strength: { value: 0.42 })
    runtime.dispatch_flat("MutationClampGrowth::Organ.Bound", id: "o3")

    organ = repository_for(runtime).find("o3")
    expect(organ[:strength][:value]).to eq(0.42)
  end

  # A never-set numeric field clamps as zero, like increment/decrement/multiply; clamping
  # 0.0 into [0.0, 1.0] leaves it unchanged.
  it "treats a phantom (never-set) numeric field as zero rather than refusing TypeMismatch", :aggregate_failures do
    runtime = boot_mutation_clamp
    runtime.dispatch_flat("MutationClampGrowth::Organ.OpenBare", id: { value: "o4" })

    expect { runtime.dispatch_flat("MutationClampGrowth::Organ.Bound", id: "o4") }.not_to raise_error

    organ = repository_for(runtime).find("o4")
    expect(organ[:strength][:value]).to eq(0.0)
  end
end
