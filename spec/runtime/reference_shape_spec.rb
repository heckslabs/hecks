require "spec_helper"

# A reference is an ID, so an object is not one.
# The refusal wording is contract (corpus scripts pin it byte for byte), so it is exact.
RSpec.describe "a reference that arrives as an object" do
  SETTLEMENT = File.join(InMemoryDomain::ROOT, "spec/fixtures/settlement.bluebook")

  def boot_settlement
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(SETTLEMENT)
      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    end
  end

  let(:runtime) { boot_settlement }

  before do
    runtime.dispatch_flat("Wire::Drawer.Open", number: { value: "a" })
    runtime.dispatch_flat("Wire::Drawer.Open", number: { value: "b" })
  end

  def ask(reference, **endpoints)
    runtime.dispatch_flat("Wire::Wire.Ask", reference: { value: reference }, amount: { cents: 100 }, **endpoints)
  end

  it "is refused, and says what to send instead" do
    expect { ask("w1", source: { value: "a" }, destination: "b") }
      .to raise_error(Hecks::Runtime::TypeMismatch,
                      "Ask refused — a reference is an id, and source arrived as an object (Drawer is known by number)")
  end

  # Declaration order, not payload order: the walk is over the command's own attributes.
  it "names the first reference the command declares, not the first one passed" do
    expect { ask("w1", destination: { value: "b" }, source: { value: "a" }) }
      .to raise_error(Hecks::Runtime::TypeMismatch, /and source arrived as an object/)
  end

  # The accepted form is stored as the scalar, not re-wrapped downstream.
  it "accepts the id, and stores it as the id", :aggregate_failures do
    ask("w1", source: "a", destination: "b")

    wire = runtime.registry.repository("Wire", runtime.registry.bluebook("Wire").aggregate("Wire")).find("w1")

    expect(wire[:source]).to eq("a")
    expect(wire[:destination]).to eq("b")
  end

  # A bare Boolean, Array or null must be refused in normalize_args like Rust's from_json,
  # not stringified into a lookup key or skipped as nil.
  describe "a non-string, non-object reference argument" do
    {
      "a bare Boolean (false)" => false,
      "a bare Boolean (true)"  => true,
      "a bare Array"           => [8, 8]
    }.each do |description, malformed|
      it "refuses #{description} as a wrong shape, not a lookup" do
        shown = malformed.is_a?(Array) ? malformed.to_json : malformed

        expect { ask("w3", source: malformed, destination: "b") }
          .to raise_error(Hecks::Runtime::TypeMismatch,
                          "Ask refused — a reference is an id, and source arrived as #{shown} (Drawer is known by number)")
      end
    end

    it "refuses a REQUIRED reference offered as null, rather than reaching the command's own given" do
      expect { ask("w4", source: nil, destination: "b") }
        .to raise_error(Hecks::Runtime::TypeMismatch,
                        "Ask refused — a reference is an id, and source arrived as nil (Drawer is known by number)")
    end
  end

  # An optional reference still passes an explicit null through; the caller may have nothing yet.
  describe "an optional reference argument" do
    # Not HOP_CHAIN: query_hop_spec.rb owns that name and load_hygiene_spec refuses duplicates.
    OPTIONAL_REFERENCE_HOP_CHAIN = File.join(InMemoryDomain::ROOT, "spec/fixtures/hop_chain.bluebook")

    def boot_hop_chain
      registry = Hecks::Runtime::Registry.new

      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Kernel.load(OPTIONAL_REFERENCE_HOP_CHAIN)
        Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
      end
    end

    let(:hop_chain_runtime) { boot_hop_chain }

    it "accepts an explicit null for a reference declared optional: true" do
      expect do
        hop_chain_runtime.dispatch_flat("HopChain::Proposal.Draft", number: { value: "p1" }, engagement: nil)
      end.not_to raise_error
    end

    it "still refuses a wrong NON-NULL shape on that same optional reference" do
      expect do
        hop_chain_runtime.dispatch_flat("HopChain::Proposal.Draft", number: { value: "p2" }, engagement: false)
      end.to raise_error(Hecks::Runtime::TypeMismatch,
                         "Draft refused — a reference is an id, and engagement arrived as false " \
                         "(Engagement is known by reference)")
    end
  end

  # A query's reference argument is refused like a command's, so no path reads a wrapped id.
  describe "a read model's reference argument" do
    BANKING = InMemoryDomain::BANKING_BLUEBOOK_DIR

    def boot_banking
      registry = Hecks::Runtime::Registry.new

      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        load_bluebook_files(BANKING)
        Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
      end
    end

    def banking_with_customer
      banking = boot_banking
      banking.dispatch_flat("Banking::Customer.Register", reference: { value: "c" },
                            name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
      banking
    end

    it "is refused by the query's own name" do
      banking = banking_with_customer

      expect { banking.query("Banking.customer_portfolio", customer: { value: "c" }) }
        .to raise_error(Hecks::Runtime::TypeMismatch,
                        "customer_portfolio refused — a reference is an id, and customer arrived as an object")
    end

    it "answers when it is given the id" do
      banking = banking_with_customer

      expect(banking.query("Banking.customer_portfolio", customer: "c")).not_to be_empty
    end
  end
end
