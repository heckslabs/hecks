require "spec_helper"
require_relative "support/inline_bluebook_boot"

# Pins increment/decrement/multiply on a phantom field (VO-typed, no default, nil until first
# touched), where the current value is a raw 0 and the amount must not be Value-wrapped alone.
#
# Amounts are literals: a Symbol source arrives already wrapped and cannot reproduce the bug.
RSpec.describe "mutation Value-wrap asymmetry fix" do
  include InlineBluebookBoot

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

  # A breaker opened on `id`, its count still a phantom field.
  def booted_breaker(id)
    boot_value_wrap.tap { |runtime| runtime.dispatch_flat("MutationValueWrapGrowth::Breaker.Open", id: { value: id }) }
  end

  def dispatch_breaker(runtime, verb, id) = runtime.dispatch_flat("MutationValueWrapGrowth::Breaker.#{verb}", id: id)

  def breaker_count(runtime, id) = repository_for(runtime).find(id)[:count][:value]

  it "increments a phantom (never-touched) VO-typed field on its FIRST mutation, not just later ones" do
    runtime = booted_breaker("b1")
    dispatch_breaker(runtime, "RecordFailure", "b1")

    expect(breaker_count(runtime, "b1")).to eq(1)
  end

  it "keeps mutating correctly on the SECOND increment, once the field is no longer phantom" do
    runtime = booted_breaker("b2")
    2.times { dispatch_breaker(runtime, "RecordFailure", "b2") }

    expect(breaker_count(runtime, "b2")).to eq(2)
  end

  it "multiplies a phantom field correctly on its first mutation too" do
    runtime = booted_breaker("b3")
    dispatch_breaker(runtime, "Scale", "b3")

    # 0 * 5 stays 0: this pins that the phantom path completes without raising.
    expect(breaker_count(runtime, "b3")).to eq(0)
  end
end
