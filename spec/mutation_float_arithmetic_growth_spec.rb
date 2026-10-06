require "spec_helper"
require_relative "support/inline_bluebook_boot"

# Pins Float support in CommandRules::Arithmetic's increment/decrement ops: a
# Float-typed field must not raise TypeMismatch on its own declared step.
RSpec.describe "Float arithmetic on increment/decrement" do
  include InlineBluebookBoot

  FLOAT_ARITHMETIC_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "FloatArithmeticGrowth" do
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

        command "Grow" do
          reference_to Organ
          attribute :amount, Strength

          sets :strength, increment: :amount
          emits "OrganGrew"
        end

        command "Fatigue" do
          reference_to Organ
          attribute :amount, Strength

          sets :strength, decrement: :amount
          emits "OrganFatigued"
        end
      end
    end
  BLUEBOOK

  def repository_for(runtime)
    aggregate = runtime.registry.bluebook("FloatArithmeticGrowth").aggregate("Organ")
    runtime.registry.repository("FloatArithmeticGrowth", aggregate)
  end

  def boot_float_arithmetic
    boot(FLOAT_ARITHMETIC_SOURCE, "FloatArithmeticGrowth") do
      FloatArithmeticGrowth::Organ.persisted_by("Memory")
    end
  end

  it "increments a Float-typed value object field" do
    runtime = boot_float_arithmetic
    runtime.dispatch_flat("FloatArithmeticGrowth::Organ.Open", id: { value: "o1" }, strength: { value: 0.5 })
    runtime.dispatch_flat("FloatArithmeticGrowth::Organ.Grow", id: "o1", amount: { value: 0.02 })

    organ = repository_for(runtime).find("o1")
    expect(organ[:strength][:value]).to be_within(0.0001).of(0.52)
  end

  it "decrements a Float-typed value object field" do
    runtime = boot_float_arithmetic
    runtime.dispatch_flat("FloatArithmeticGrowth::Organ.Open", id: { value: "o2" }, strength: { value: 0.5 })
    runtime.dispatch_flat("FloatArithmeticGrowth::Organ.Fatigue", id: "o2", amount: { value: 0.1 })

    organ = repository_for(runtime).find("o2")
    expect(organ[:strength][:value]).to be_within(0.0001).of(0.4)
  end
end
