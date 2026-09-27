require "spec_helper"
require "tempfile"

# Pins increment/decrement/multiply on a phantom field (VO-typed, no default, nil until first
# touched), where the current value is a raw 0 and the amount must not be Value-wrapped alone.
#
# Amounts are literals: a Symbol source arrives already wrapped and cannot reproduce the bug.
RSpec.describe "mutation Value-wrap asymmetry fix" do
  def boot(source, hecksagon_name, &binds)
    file = Tempfile.new(["mutation-value-wrap-asymmetry-growth-", ".bluebook"])
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

  # `count` has no default, so it is a phantom field until first touched.
  MUTATION_VALUE_WRAP_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "MutationValueWrapGrowth" do
      aggregate "Breaker" do
        identified_by :id

        value_object "BreakerId" do
          attribute :value, String
        end

        value_object "FailureCount" do
          attribute :value, Integer
        end

        attribute :id,    BreakerId
        attribute :count, FailureCount

        command "Open" do
          attribute :id, BreakerId
          emits "BreakerOpened"
        end

        command "RecordFailure" do
          reference_to Breaker

          sets :count, increment: 1
          emits "FailureRecorded"
        end

        command "Scale" do
          reference_to Breaker

          sets :count, multiply: 5
          emits "FailureScaled"
        end
      end
    end
  BLUEBOOK

  def repository_for(runtime)
    aggregate = runtime.registry.bluebook("MutationValueWrapGrowth").aggregate("Breaker")
    runtime.registry.repository("MutationValueWrapGrowth", aggregate)
  end

  def boot_value_wrap
    boot(MUTATION_VALUE_WRAP_SOURCE, "MutationValueWrapGrowth") do
      MutationValueWrapGrowth::Breaker.persisted_by("Memory")
    end
  end

  it "increments a phantom (never-touched) VO-typed field on its FIRST mutation, not just later ones" do
    runtime = boot_value_wrap
    runtime.dispatch_flat("MutationValueWrapGrowth::Breaker.Open", id: { value: "b1" })
    runtime.dispatch_flat("MutationValueWrapGrowth::Breaker.RecordFailure", id: "b1")

    breaker = repository_for(runtime).find("b1")
    expect(breaker[:count][:value]).to eq(1)
  end

  it "keeps mutating correctly on the SECOND increment, once the field is no longer phantom" do
    runtime = boot_value_wrap
    runtime.dispatch_flat("MutationValueWrapGrowth::Breaker.Open", id: { value: "b2" })
    runtime.dispatch_flat("MutationValueWrapGrowth::Breaker.RecordFailure", id: "b2")
    runtime.dispatch_flat("MutationValueWrapGrowth::Breaker.RecordFailure", id: "b2")

    breaker = repository_for(runtime).find("b2")
    expect(breaker[:count][:value]).to eq(2)
  end

  it "multiplies a phantom field correctly on its first mutation too" do
    runtime = boot_value_wrap
    runtime.dispatch_flat("MutationValueWrapGrowth::Breaker.Open", id: { value: "b3" })
    runtime.dispatch_flat("MutationValueWrapGrowth::Breaker.Scale", id: "b3")

    breaker = repository_for(runtime).find("b3")
    # 0 * 5 stays 0: this pins that the phantom path completes without raising.
    expect(breaker[:count][:value]).to eq(0)
  end
end
