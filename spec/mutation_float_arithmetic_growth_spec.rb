require "spec_helper"
require "tempfile"

# Real dispatch coverage for Float/Numeric arithmetic on the EXISTING
# increment/decrement ops: CommandRules::Arithmetic#arithmetic/
# #arithmetic_value_object were Integer-only before this fix, so any
# Float-typed field (miette's own organ math, "increment: 0.02") raised
# a TypeMismatch the caller never made. Widened from Integer to Numeric.
# Independent of `multiply`/`clamp` landing -- those are brand-new ops
# with their own Numeric checks from birth and never call #arithmetic/
# #arithmetic_value_object at all; this fix is exclusively a value-add
# to the two pre-existing ops.
RSpec.describe "Float arithmetic on increment/decrement" do
  def boot(source, hecksagon_name, &binds)
    file = Tempfile.new(["mutation-float-arithmetic-growth-", ".bluebook"])
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
    runtime.dispatch("FloatArithmeticGrowth::Organ.Open", id: { value: "o1" }, strength: { value: 0.5 })
    runtime.dispatch("FloatArithmeticGrowth::Organ.Grow", id: "o1", amount: { value: 0.02 })

    organ = repository_for(runtime).find("o1")
    expect(organ[:strength][:value]).to be_within(0.0001).of(0.52)
  end

  it "decrements a Float-typed value object field" do
    runtime = boot_float_arithmetic
    runtime.dispatch("FloatArithmeticGrowth::Organ.Open", id: { value: "o2" }, strength: { value: 0.5 })
    runtime.dispatch("FloatArithmeticGrowth::Organ.Fatigue", id: "o2", amount: { value: 0.1 })

    organ = repository_for(runtime).find("o2")
    expect(organ[:strength][:value]).to be_within(0.0001).of(0.4)
  end
end
