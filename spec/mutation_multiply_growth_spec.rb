require "spec_helper"
require_relative "support/inline_bluebook_boot"

# Real dispatch coverage for the `multiply` mutation op: `current * amount`,
# the scaling counterpart to increment/decrement's add/subtract (i106).
RSpec.describe "mutation op multiply" do
  include InlineBluebookBoot

  MUTATION_MULTIPLY_SOURCE = <<~BLUEBOOK.freeze
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
      MutationMultiplyGrowth::Organ.persisted_by("Memory")
    end
  end

  it "scales a value-object field by the given factor" do
    runtime = boot_mutation_multiply
    runtime.dispatch_flat("MutationMultiplyGrowth::Organ.Open", id: { value: "o1" }, strength: { value: 1.0 })
    runtime.dispatch_flat("MutationMultiplyGrowth::Organ.Decay", id: "o1", factor: { value: 0.98 })

    organ = repository_for(runtime).find("o1")
    expect(organ[:strength][:value]).to be_within(0.0001).of(0.98)
  end
end
