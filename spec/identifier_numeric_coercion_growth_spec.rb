require "spec_helper"
require "tempfile"

# Real dispatch coverage for Value::Coercion#coerce_identifier: when an
# aggregate's identified_by field is itself numeric (Integer/Float, not the
# overwhelmingly common String), #from_identifier re-seeding a freshly-
# hydrated instance from the DERIVED IDENTITY STRING used to round-trip it
# back in as the wrong Ruby type, and #build's own check_numeric_fields (a
# rule meant to catch a genuine CALLER mismatch) then refused the runtime's
# own internal identity seed instead -- blocking every command on any
# aggregate with a numeric identity field, unconditionally, valid input or
# not.
RSpec.describe "identity coercion on a numeric identified_by field" do
  def boot(source, hecksagon_name, &binds)
    file = Tempfile.new(["identifier-numeric-coercion-growth-", ".bluebook"])
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

  NUMERIC_IDENTITY_SOURCE = <<~BLUEBOOK
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
      ::NumericIdentityGrowth::SleepCycle.persisted_by("Memory")
    end
  end

  it "creates a record whose identity field is genuinely numeric, not a type mismatch" do
    runtime = boot_numeric_identity

    expect { runtime.dispatch("NumericIdentityGrowth::SleepCycle.StartCycle", cycle_number: { value: 1 }) }
      .not_to raise_error

    cycle = repository_for(runtime).find("1")
    expect(cycle[:cycle_number][:value]).to eq(1)
  end

  it "dispatches a SECOND command against the same numeric-identity record without a false TypeMismatch" do
    runtime = boot_numeric_identity
    runtime.dispatch("NumericIdentityGrowth::SleepCycle.StartCycle", cycle_number: { value: 1 })

    expect { runtime.dispatch("NumericIdentityGrowth::SleepCycle.AdvanceStage", cycle_number: 1) }
      .not_to raise_error
  end
end
