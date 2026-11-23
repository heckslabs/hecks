require "hecks"

# A bounded step is one write: `increment:` or `decrement:` beside `clamp: [min, max]`. What the
# step does to a weight is in examples/bounded_step/bluebook/bounded_step.behaviors; what stays
# here is how the declaration reads, what it refuses, and how it appears in the IR.
RSpec.describe "a bounded step on a field" do
  def in_registry
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      yield
    end
    registry
  end

  # One command on a Thing declaring `sets :weight, **ops` after the arguments it names.
  def command_with(*writes)
    body = thing_body(writes)
    in_registry { Hecks.bluebook("Stepped") { aggregate("Thing", &body) } }
      .bluebook("Stepped").aggregate("Thing").command("Do")
  end

  def thing_body(writes)
    proc do
      identified_by :thing_id
      value_object("Size") { attribute :value, Integer }
      attribute :weight, Size
      command("Do") do
        %i[gain step a].each { |name| attribute name, Size }
        writes.each { |ops| sets :weight, **ops }
      end
    end
  end

  it "records one mutation that keeps its op and carries the bounds", :aggregate_failures do
    mutation = command_with({ increment: :gain, clamp: [0, 100] }).mutations.first

    expect([mutation.op, mutation.source, mutation.bounds]).to eq([:increment, :gain, [0, 100]])
  end

  it "reads a decrement the same way" do
    mutation = command_with({ decrement: :step, clamp: [0, 100] }).mutations.first

    expect([mutation.op, mutation.bounds]).to eq([:decrement, [0, 100]])
  end

  it "emits the bounds only when the step has them", :aggregate_failures do
    bounded = command_with({ increment: :gain, clamp: [0, 100] }).mutations.first
    plain   = command_with({ increment: :gain }).mutations.first

    expect(bounded.to_h[:bounds]).to eq([0, 100])
    expect(plain.to_h).not_to include(:bounds)
  end

  it "still writes a field at most once" do
    expect { command_with({ increment: :a, clamp: [0, 9] }, { to: 1 }) }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /writes weight twice/)
  end

  it "still refuses two ops other than a step and its clamp" do
    expect { command_with({ multiply: :a, clamp: [0, 9] }) }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /one mutation, one meaning/)
  end

  it "keeps a bare clamp as the op it was" do
    mutation = command_with({ clamp: [0, 9] }).mutations.first

    expect([mutation.op, mutation.source, mutation.bounds]).to eq([:clamp, [0, 9], nil])
  end

  it "refuses bounds that are not a low and a high number in order" do
    expect { command_with({ increment: :a, clamp: [9, 0] }) }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /clamp/)
  end
end
