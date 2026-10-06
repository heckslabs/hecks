require "spec_helper"

RSpec.describe "sets arithmetic" do
  TILL_BLUEBOOK = File.join(InMemoryDomain::ROOT, "spec/fixtures/till.bluebook")

  TILL_MARKS = [{ amount: 10_000, direction: "in" }, { amount: 2_500, direction: "out" }].freeze

  def boot_till
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
       InMemoryDomain::PRISM_ADAPTER, TILL_BLUEBOOK].each { |file| Kernel.load(file) }
      Hecks::Runtime::Loader.bind_runtime(
        Hecks::Runtime::Dispatcher.new(registry)
      )
    end
  end

  def till_event(runtime, command, **args)
    runtime.dispatch_flat("TillRoom::Till.#{command}", number: { value: "till-1" }, **args)
  end

  # A booted till, opened, with each [command, cents] move applied in order.
  def till_after(*moves)
    boot_till.tap do |runtime|
      till_event(runtime, "OpenTill")
      moves.each { |command, cents| till_event(runtime, command, amount: { cents: cents }) }
    end
  end

  it "increments from the declared default, and keeps counting" do
    runtime = boot_till
    runtime.dispatch_flat("TillRoom::Till.OpenTill", number: { value: "till-1" })
    runtime.dispatch_flat("TillRoom::Till.TakeIn", number: { value: "till-1" }, amount: { cents: 10_000 })
    runtime.dispatch_flat("TillRoom::Till.TakeIn", number: { value: "till-1" }, amount: { cents: 2_500 })

    expect(TillRoom::Till.find("till-1").balance.to_h).to eq(cents: 12_500)
  end

  it "decrements, and the running balance is exact" do
    runtime = boot_till
    runtime.dispatch_flat("TillRoom::Till.OpenTill", number: { value: "till-1" })
    runtime.dispatch_flat("TillRoom::Till.TakeIn", number: { value: "till-1" }, amount: { cents: 10_000 })
    runtime.dispatch_flat("TillRoom::Till.PayOut", number: { value: "till-1" }, amount: { cents: 2_500 })

    expect(TillRoom::Till.find("till-1").balance.to_h).to eq(cents: 7_500)
  end

  it "increments by a literal when the bluebook says a number" do
    runtime = boot_till
    runtime.dispatch_flat("TillRoom::Till.OpenTill", number: { value: "till-1" })
    runtime.dispatch_flat("TillRoom::Till.Bump", number: { value: "till-1" })

    expect(TillRoom::Till.find("till-1").balance.to_h).to eq(cents: 500)
  end

  it "refuses a non-Integer amount loudly, leaving the balance untouched", :aggregate_failures do
    runtime = till_after(["TakeIn", 10_000])

    # Must be refused at the payload gate: an EvaluationError is not in DOMAIN_REFUSALS.
    expect { till_event(runtime, "TakeIn", amount: { cents: "lots" }) }
      .to raise_error(Hecks::Runtime::TypeMismatch, 'Money.cents expects Integer, got "lots"')

    expect(TillRoom::Till.find("till-1").balance.to_h).to eq(cents: 10_000)
  end

  it "writes an appended literal as itself, beside the argument fields" do
    till_after(["TakeIn", 10_000], ["PayOut", 2_500])

    expect(TillRoom::Till.find("till-1").marks.map(&:to_h)).to eq(TILL_MARKS)
  end

  VOID_BLUEBOOK = proc do
    vision "An aggregate whose command sets a field it never declared."
    supporting

    aggregate "Widget" do
      description "A widget with exactly one declared field."

      attribute :label, Label

      value_object "Label" do
        attribute :value, String

        invariant("a widget is labelled") { !value.to_s.empty? }
      end

      command "Make" do
        role "Maker"
        goal "Bring a widget into being"

        attribute :label, Label

        emits "WidgetMade"
      end

      command "Rename" do
        role "Maker"
        goal "Set a field the aggregate never declared"

        reference_to Widget
        attribute :nickname, Label

        # :nickname is not an attribute of Widget — :label is the only one.
        sets :nickname

        emits "WidgetRenamed"
      end
    end
  end

  # The language only requires a mutation target to be non-empty, so a sets naming an
  # undeclared field is well formed yet writes into nothing at runtime.
  describe "a mutation into a void" do
    def in_registry
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        yield
      end
      registry
    end

    def build_void_target = in_registry { Hecks.bluebook("Void", &VOID_BLUEBOOK) }

    it "refuses a sets naming a field the aggregate never declared" do
      expect { build_void_target }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /nickname/)
    end
  end
end
