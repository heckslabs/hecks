require "spec_helper"
require_relative "support/inline_bluebook_boot"

# Value::Coercion#coerce_identifier on a numeric identified_by: re-seeding identity from its string
# must not trip check_numeric_fields, which would block every command on such an aggregate.
RSpec.describe "identity coercion on a numeric identified_by field" do
  include InlineBluebookBoot

  NUMERIC_IDENTITY_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "NumericIdentityGrowth" do
      aggregate "SleepCycle" do
        identified_by :cycle_number

        value_object "CycleNumber" do
          attribute :value, Integer
        end

        attribute :cycle_number, CycleNumber

        command "StartCycle" do
          attribute :cycle_number, CycleNumber
          emits "CycleStarted"
        end

        command "AdvanceStage" do
          reference_to SleepCycle
          emits "StageAdvanced"
        end
      end
    end
  BLUEBOOK

  def repository_for(runtime)
    aggregate = runtime.registry.bluebook("NumericIdentityGrowth").aggregate("SleepCycle")
    runtime.registry.repository("NumericIdentityGrowth", aggregate)
  end

  def boot_numeric_identity
    boot(NUMERIC_IDENTITY_SOURCE, "NumericIdentityGrowth") do
      NumericIdentityGrowth::SleepCycle.persisted_by("Memory")
    end
  end

  it "creates a record whose identity field is genuinely numeric, not a type mismatch", :aggregate_failures do
    runtime = boot_numeric_identity

    expect { runtime.dispatch_flat("NumericIdentityGrowth::SleepCycle.StartCycle", cycle_number: { value: 1 }) }
      .not_to raise_error

    cycle = repository_for(runtime).find("1")
    expect(cycle[:cycle_number][:value]).to eq(1)
  end

  it "dispatches a SECOND command against the same numeric-identity record without a false TypeMismatch" do
    runtime = boot_numeric_identity
    runtime.dispatch_flat("NumericIdentityGrowth::SleepCycle.StartCycle", cycle_number: { value: 1 })

    expect { runtime.dispatch_flat("NumericIdentityGrowth::SleepCycle.AdvanceStage", cycle_number: 1) }
      .not_to raise_error
  end
end
