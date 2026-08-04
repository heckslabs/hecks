
require "spec_helper"

RSpec.describe "then_set arithmetic" do
  TILL_BLUEBOOK = File.join(InMemoryDomain::ROOT, "spec/fixtures/till.bluebook")

  def boot_till
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(TILL_BLUEBOOK)
      Hecksagain::Runtime::Loader.bind_runtime(
        Hecksagain::Runtime::Dispatcher.new(registry)
      )
    end
  end

  it "increments from the declared default, and keeps counting" do
    runtime = boot_till
    runtime.dispatch("TillRoom::Till.OpenTill", number: { value: "till-1" })
    runtime.dispatch("TillRoom::Till.TakeIn", number: { value: "till-1" }, amount: { cents: 10_000 })
    runtime.dispatch("TillRoom::Till.TakeIn", number: { value: "till-1" }, amount: { cents: 2_500 })

    expect(TillRoom::Till.find("till-1").balance.to_h).to eq(cents: 12_500)
  end

  it "decrements, and the running balance is exact" do
    runtime = boot_till
    runtime.dispatch("TillRoom::Till.OpenTill", number: { value: "till-1" })
    runtime.dispatch("TillRoom::Till.TakeIn", number: { value: "till-1" }, amount: { cents: 10_000 })
    runtime.dispatch("TillRoom::Till.PayOut", number: { value: "till-1" }, amount: { cents: 2_500 })

    expect(TillRoom::Till.find("till-1").balance.to_h).to eq(cents: 7_500)
  end

  it "increments by a literal when the bluebook says a number" do
    runtime = boot_till
    runtime.dispatch("TillRoom::Till.OpenTill", number: { value: "till-1" })
    runtime.dispatch("TillRoom::Till.Bump", number: { value: "till-1" })

    expect(TillRoom::Till.find("till-1").balance.to_h).to eq(cents: 500)
  end

  it "refuses a non-Integer amount loudly, leaving the balance untouched" do
    runtime = boot_till
    runtime.dispatch("TillRoom::Till.OpenTill", number: { value: "till-1" })
    runtime.dispatch("TillRoom::Till.TakeIn", number: { value: "till-1" }, amount: { cents: 10_000 })

    # Refused at the payload gate as a DOMAIN refusal, not deep in a predicate
    # as an EvaluationError — the latter is not in DOMAIN_REFUSALS, so it used
    # to be recorded beside genuine refusals while actually being a crash.
    expect { runtime.dispatch("TillRoom::Till.TakeIn", number: { value: "till-1" }, amount: { cents: "lots" }) }
      .to raise_error(Hecksagain::Runtime::TypeMismatch,
                      'Money.cents expects Integer, got "lots"')

    expect(TillRoom::Till.find("till-1").balance.to_h).to eq(cents: 10_000)
  end

  it "writes an appended literal as itself, beside the argument fields" do
    runtime = boot_till
    runtime.dispatch("TillRoom::Till.OpenTill", number: { value: "till-1" })
    runtime.dispatch("TillRoom::Till.TakeIn", number: { value: "till-1" }, amount: { cents: 10_000 })
    runtime.dispatch("TillRoom::Till.PayOut", number: { value: "till-1" }, amount: { cents: 2_500 })

    expect(TillRoom::Till.find("till-1").marks.map(&:to_h)).to eq([
      { amount: 10_000, direction: "in" },
      { amount: 2_500,  direction: "out" }
    ])
  end

  # A mutation names a target — but must the target EXIST?
  #
  # The language says only `given("a mutation names a target") { !target.value
  # .to_s.empty? }`. Non-emptiness, nothing more. So a then_set naming a field
  # the aggregate never declared is, as far as the language is concerned, well
  # formed — and at runtime it writes into nothing while every check stays green,
  # which is the signature of every defect this corpus has produced.
  #
  # Found while giving CardPayment a `disputed_by` : the then_set was in place
  # before the aggregate field was, and nothing said so.
  describe "a mutation into a void" do
    def in_registry
      registry = Hecksagain::Runtime::Registry.new
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        yield
      end
      registry
    end

    def build_void_target
      in_registry do
        Hecks.bluebook("Void") do
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

              # :nickname is NOT an attribute of Widget — :label is the only one.
              then_set :nickname, to: :nickname

              emits "WidgetRenamed"
            end
          end
        end
      end
    end

    it "refuses a then_set naming a field the aggregate never declared" do
      expect { build_void_target }
        .to raise_error(Hecksagain::Bluebook::DSL::Malformed, /nickname/)
    end
  end
end
