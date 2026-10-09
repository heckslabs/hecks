require "spec_helper"
require "tmpdir"

# `sets` taking arithmetic as its source: `+ - * /` over a command's arguments, the record's own
# fields and whole numbers. The grammar levels, the floor and fault rules, and the way a
# computed value is stored are held here; spec/corpus/rust_conformance/computed_sets.json holds
# the Ruby and Rust engines to the same answers.
RSpec.describe "a sets that computes its value" do
  COMPUTED_SETS_FIXTURE = File.join(InMemoryDomain::ROOT, "spec/fixtures/rust_project/computed_sets_fixture/bluebook",
                                    "computed_sets_fixture.bluebook")

  def resolve(text, **attrs) = Hecks::Bluebook::Expression::Resolver.resolve(text, {}, attrs)

  def fault_message(text, **attrs)
    resolve(text, **attrs)
  rescue Hecks::Bluebook::Expression::EvaluationError => e
    e.message
  end

  def booted
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
       InMemoryDomain::PRISM_ADAPTER, COMPUTED_SETS_FIXTURE].each { |file| Kernel.load(file) }
    end
    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let(:runtime) { booted }

  def dispatch(verb, **args) = runtime.dispatch_flat("ComputedSetsFixture::Settlement.#{verb}", **args)

  def stored(ref, field)
    aggregate = runtime.registry.bluebook("ComputedSetsFixture").aggregate("Settlement")
    runtime.registry.repository("ComputedSetsFixture", aggregate).find(ref)[field].value
  end

  def mutation_source(command, target)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) { Kernel.load(COMPUTED_SETS_FIXTURE) }
    settlement = registry.bluebook("ComputedSetsFixture").aggregate("Settlement")
    settlement.command(command).mutations.find { |mutation| mutation.target == target }.source
  end

  it "reads * and / left to right, binding tighter than + and -" do
    expect(resolve("2 + 3 * 4 - 10 / 5")).to eq(12)
  end

  it "lets parentheses override the levels" do
    expect(resolve("(2 + 3) * 4")).to eq(20)
  end

  it "rounds an integer quotient toward negative infinity", :aggregate_failures do
    expect(resolve("10801 * 50 / 100")).to eq(5400)
    expect([resolve("-7 / 2"), resolve("7 / -2"), resolve("-7 / -2")]).to eq([-4, -4, 3])
  end

  it "reads a minus after an operand as subtraction and a minus before a number as its sign" do
    expect(resolve("5 - -3")).to eq(8)
  end

  it "divides floats as floats" do
    expect(resolve("7.0 / 2")).to eq(3.5)
  end

  it "faults on a zero divisor, integer or float", :aggregate_failures do
    expect(fault_message("1 / 0")).to eq("divided by 0")
    expect(fault_message("1.5 / 0.0")).to eq("divided by 0")
  end

  it "faults on a result outside signed 64 bits", :aggregate_failures do
    expect(fault_message("9223372036854775807 * 2")).to include("multiplication overflowed")
    expect(fault_message("-9223372036854775808 / -1")).to include("division overflowed")
  end

  it "records the arithmetic as a computed source with its canonical text" do
    expect(mutation_source("Settle", :refund)).to eq(Hecks::Computed.new("paid * rate / 100"))
  end

  it "stores a computed value in the target's single-field value object", :aggregate_failures do
    dispatch("Open", ref: "s1", paid: 10_801)
    dispatch("Settle", settlement: "s1", rate: 50, shortfall: 801)

    expect(stored("s1", :refund)).to eq(5400)
    expect(stored("s1", :remaining)).to eq(10_000)
  end

  it "subtracts a negative operand" do
    dispatch("Open", ref: "s1", paid: 10_801)
    dispatch("Settle", settlement: "s1", rate: 33, shortfall: -2000)

    expect(stored("s1", :remaining)).to eq(12_801)
  end

  it "leaves the record unchanged when the computation faults", :aggregate_failures do
    dispatch("Open", ref: "s1", paid: 100)

    expect { dispatch("Share", settlement: "s1", amount: 7, parts: 0) }.to raise_error(/divided by 0/)
    expect(stored("s1", :share)).to eq(0)
  end

  # A one-aggregate bluebook whose `Compute` command reads `operand` in a computed `sets`.
  def operand_bluebook(operand)
    <<~BLUEBOOK
      Hecks.bluebook "PathOperands" do
        vision "A command reading a path into a value object."
        core
        aggregate "Thing" do
          identified_by :ref
          attribute :ref, ThingRef
          attribute :charged, Charge, default: { cents: 0, currency: "USD" }
          attribute :tags, list_of(Tag)
          attribute :out, Cents, default: { value: 0 }
          value_object("ThingRef") { attribute :value, String }
          value_object("Cents") { attribute :value, Integer }
          value_object("Tag") { attribute :value, String }
          value_object("Charge") { attribute :cents, Integer; attribute :currency, String }
          command "Compute" do
            goal "Read an operand"
            reference_to Thing
            attribute :discount, Charge
            sets :out, to: #{operand} * 2
            emits "Computed"
          end
        end
      end
    BLUEBOOK
  end

  def load_operand(operand)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "path_operands.bluebook")
      File.write(path, operand_bluebook(operand))
      Hecks.with_registry(Hecks::Runtime::Registry.new) { Kernel.load(path) }
    end
  end

  it "reads a path into a multi-field value object, on the record or an argument", :aggregate_failures do
    expect { load_operand("charged.cents") }.not_to raise_error
    expect { load_operand("discount.cents") }.not_to raise_error
  end

  it "records a dotted operand as the dotted path in the canonical text" do
    expect(mutation_source("Late", :late_owed)).to eq(Hecks::Computed.new("charged.cents * late_percent.value / 100"))
  end

  it "refuses a path naming a field the value object does not declare" do
    expect { load_operand("charged.nonsense") }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /charged\.nonsense.*does not declare/)
  end

  it "refuses a path that runs through a list" do
    expect { load_operand("tags.value") }.to raise_error(Hecks::Bluebook::DSL::Malformed, /tags\.value.*list/)
  end

  it "refuses a bare multi-field value object, naming the field to use" do
    expect { load_operand("charged") }.to raise_error(Hecks::Bluebook::DSL::Malformed, /charged.*several fields.*charged\.cents/)
  end

  def charge_late_and_discount
    dispatch("Open", ref: "s1", paid: 100)
    dispatch("Charge", settlement: "s1", charged: { cents: 10_801, currency: "USD" })
    dispatch("Late", settlement: "s1", late_percent: 50)
    dispatch("Discount", settlement: "s1", discount: { cents: 801, currency: "USD" })
  end

  it "computes from a path on the record and a path on an argument", :aggregate_failures do
    charge_late_and_discount

    expect(stored("s1", :late_owed)).to eq(5400)
    expect(stored("s1", :net)).to eq(10_000)
  end
end
