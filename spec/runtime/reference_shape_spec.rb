require "spec_helper"

# A REFERENCE IS AN ID, SO AN OBJECT IS NOT ONE.
#
# Nothing coerced a reference anywhere: the value-object lookup misses
# on "Reference<Drawer>", which is no value object's name, so the argument was
# stored exactly as it arrived. There was nowhere it could be refused, and so
# whatever the first caller happened to write — `{"value":"a"}` — became the
# shape the corpus used for years.
#
# The refusal's WORDING is contract, not prose: the corpus scripts pin refusal
# text byte for byte, so the string here is asserted exactly.
RSpec.describe "a reference that arrives as an object" do
  SETTLEMENT = File.join(InMemoryDomain::ROOT, "spec/fixtures/settlement.bluebook")

  def boot_settlement
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(SETTLEMENT)
      Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
    end
  end

  let(:runtime) { boot_settlement }

  before do
    runtime.dispatch("Wire::Drawer.Open", number: { value: "a" })
    runtime.dispatch("Wire::Drawer.Open", number: { value: "b" })
  end

  it "is refused, and says what to send instead" do
    expect do
      runtime.dispatch("Wire::Wire.Ask", reference: { value: "w1" }, amount: { cents: 100 },
                                         source: { value: "a" }, destination: "b")
    end.to raise_error(Hecksagain::Runtime::TypeMismatch,
                       "Ask refused — a reference is an id, and source arrived as an object " \
                       "(Drawer is known by number)")
  end

  # DECLARATION ORDER, not payload order. `refuse_unknown_arguments` had to sort
  # its list because map iteration order is an accident of the store ; this one
  # walks the command's own attributes, an array with a declared order, so the
  # argument named first is stable without sorting.
  it "names the first reference the command declares, not the first one passed" do
    expect do
      runtime.dispatch("Wire::Wire.Ask", reference: { value: "w1" }, amount: { cents: 100 },
                                         destination: { value: "b" }, source: { value: "a" })
    end.to raise_error(Hecksagain::Runtime::TypeMismatch, /and source arrived as an object/)
  end

  # WITHOUT THIS THE GUARD PROVES NOTHING. A refusal on the wrapped form is only
  # half the claim ; the other half is that the accepted form is STORED as the
  # scalar, rather than quietly re-wrapped somewhere downstream.
  it "accepts the id, and stores it as the id" do
    runtime.dispatch("Wire::Wire.Ask", reference: { value: "w1" }, amount: { cents: 100 },
                                       source: "a", destination: "b")

    wire = runtime.registry.repository("Wire", runtime.registry.bluebook("Wire").aggregate("Wire")).find("w1")

    expect(wire[:source]).to eq("a")
    expect(wire[:destination]).to eq("b")
  end

  # AN ASK'S REFERENCE IS AN ID TOO, and this one closes a real split rather
  # than a hypothetical: one query path once opened a wrapped reference and
  # answered, while another read it whole and found nothing. Only a stale caller
  # would show it, which is exactly the kind of divergence that waits.
  describe "a read model's reference argument" do
    BANKING = InMemoryDomain::BANKING_BLUEBOOK_DIR

    def boot_banking
      registry = Hecksagain::Runtime::Registry.new

      Hecksagain.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        load_bluebook_files(BANKING)
        Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
      end
    end

    it "is refused by the query's own name" do
      banking = boot_banking
      banking.dispatch("Banking::Customer.Register", reference: { value: "c" },
                       name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })

      expect { banking.query("Banking.customer_portfolio", customer: { value: "c" }) }
        .to raise_error(Hecksagain::Runtime::TypeMismatch,
                        "customer_portfolio refused — a reference is an id, and customer arrived as an object")
    end

    it "answers when it is given the id" do
      banking = boot_banking
      banking.dispatch("Banking::Customer.Register", reference: { value: "c" },
                       name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })

      expect(banking.query("Banking.customer_portfolio", customer: "c")).not_to be_empty
    end
  end
end
