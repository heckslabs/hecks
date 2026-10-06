require "spec_helper"
require "tempfile"

# Value::Coercion#coerce_identifier on a numeric identified_by: re-seeding identity from its string
# must not trip check_numeric_fields, which would block every command on such an aggregate.
RSpec.describe "identity coercion on a numeric identified_by field" do
  def write_bluebook(source)
    Tempfile.new(["identifier-numeric-coercion-growth-", ".bluebook"]).tap do |file|
      file.write(source)
      file.flush
    end
  end

  def declare_in(registry, file, source, hecksagon_name, &binds)
    Hecks::Bluebook::MetaValidator.while_disabled do
      Hecks.with_registry(registry) do
        [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
         InMemoryDomain::PRISM_ADAPTER].each { |port| Kernel.load(port) }
        Kernel.eval(source, TOPLEVEL_BINDING, file.path, 1)
        Hecks.hecksagon(hecksagon_name, &binds)
      end
    end
  end

  def boot(source, hecksagon_name, &binds)
    file = write_bluebook(source)
    registry = Hecks::Runtime::Registry.new
    declare_in(registry, file, source, hecksagon_name, &binds)

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  ensure
    file&.close!
  end

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
