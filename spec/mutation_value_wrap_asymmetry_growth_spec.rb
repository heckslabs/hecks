require "spec_helper"
require "tempfile"

# Real dispatch coverage for the Value-wrap asymmetry bug fix across
# increment/decrement/multiply: #apply used to wrap `amount` into a Value
# whenever the target attribute existed, never checking whether `current`
# (the field's own existing value) was ALSO wrapped. On a PHANTOM-CREATED
# field -- a VO-typed attribute with no declared default, genuinely nil
# until first touched -- `current` came back as a raw, unwrapped 0, so the
# two sides of the same arithmetic call disagreed on Value-ness and the
# primitive path refused a correctly-typed number as a type mismatch the
# caller never made.
#
# Uses a LITERAL amount (`increment: 1`, not `increment: :amount`)
# deliberately: a Symbol source naming a COMMAND ARGUMENT arrives already
# Value-wrapped by normalize_args/coerce_declared_arguments (a separate,
# earlier coercion pass, unaffected by this fix either way), so it can
# never reproduce the asymmetry this fix addresses. A literal source is
# what stays genuinely raw all the way to #apply, which is the shape that
# actually surfaces the bug.
RSpec.describe "mutation Value-wrap asymmetry fix" do
  def boot(source, hecksagon_name, &binds)
    file = Tempfile.new(["mutation-value-wrap-asymmetry-growth-", ".bluebook"])
    file.write(source)
    file.flush

    previous = ENV["HECKSAGAIN_META_VALIDATION"]
    ENV["HECKSAGAIN_META_VALIDATION"] = "off"

    registry = Hecksagain::Runtime::Registry.new
    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.eval(source, TOPLEVEL_BINDING, file.path, 1)
      Hecks.hecksagon(hecksagon_name, &binds)
    end

    registry.verify!
    Hecksagain::Runtime::Loader.bind_runtime(
      Hecksagain::Runtime::Dispatcher.new(registry)
    )
  ensure
    ENV["HECKSAGAIN_META_VALIDATION"] = previous
    file&.close!
  end

  # `count` is declared with NO default: -- a phantom field, genuinely
  # nil until the first mutation ever touches it.
  MUTATION_VALUE_WRAP_SOURCE = <<~BLUEBOOK
    Hecks.bluebook "MutationValueWrapGrowth" do
      aggregate "Breaker" do
        identified_by { id.value }

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

          then_set :count, increment: 1
          emits "FailureRecorded"
        end

        command "Scale" do
          reference_to Breaker

          then_set :count, multiply: 5
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
      ::MutationValueWrapGrowth::Breaker.persisted_by("Memory")
    end
  end

  it "increments a phantom (never-touched) VO-typed field on its FIRST mutation, not just later ones" do
    runtime = boot_value_wrap
    runtime.dispatch("MutationValueWrapGrowth::Breaker.Open", id: { value: "b1" })
    runtime.dispatch("MutationValueWrapGrowth::Breaker.RecordFailure", id: "b1")

    breaker = repository_for(runtime).find("b1")
    expect(breaker[:count][:value]).to eq(1)
  end

  it "keeps mutating correctly on the SECOND increment, once the field is no longer phantom" do
    runtime = boot_value_wrap
    runtime.dispatch("MutationValueWrapGrowth::Breaker.Open", id: { value: "b2" })
    runtime.dispatch("MutationValueWrapGrowth::Breaker.RecordFailure", id: "b2")
    runtime.dispatch("MutationValueWrapGrowth::Breaker.RecordFailure", id: "b2")

    breaker = repository_for(runtime).find("b2")
    expect(breaker[:count][:value]).to eq(2)
  end

  it "multiplies a phantom field correctly on its first mutation too" do
    runtime = boot_value_wrap
    runtime.dispatch("MutationValueWrapGrowth::Breaker.Open", id: { value: "b3" })
    runtime.dispatch("MutationValueWrapGrowth::Breaker.Scale", id: "b3")

    breaker = repository_for(runtime).find("b3")
    # current starts at the raw, unwrapped 0 (never touched) -- 0 * 5 stays 0,
    # so this confirms the phantom path completes WITHOUT raising, not that
    # zero times anything is a meaningful business result.
    expect(breaker[:count][:value]).to eq(0)
  end
end
