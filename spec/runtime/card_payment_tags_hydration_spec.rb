require "spec_helper"

# ADR 0047: pins bare `sets :tags` hydration on the shipped `Banking::CardPayment.Authorize`.
# Reaches `InMemoryDomain::BANKING_BLUEBOOK_DIR` directly; bare top-level constants collide.
RSpec.describe "Banking::CardPayment.Authorize's own bare-sets tags list" do
  def boot_banking
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    end
  end

  def open_account(runtime)
    runtime.dispatch_flat("Banking::Customer.Register", reference: { value: "c1" },
                          name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
    runtime.dispatch_flat("Banking::Account.Open", customer: "c1", number: { value: "a1" },
                          kind: { name: "current" }, daily_limit: { cents: 1_000 })
  end

  def authorize(runtime, authorisation, tags)
    runtime.dispatch_flat("Banking::CardPayment.Authorize", account: "a1", authorisation: { value: authorisation },
                          amount: { cents: 500 }, merchant: { value: "Shop" }, tags: tags)
  end

  def stored_tags(runtime, id)
    card_payment = runtime.registry.bluebook("Banking").aggregate("CardPayment")
    runtime.registry.repository("Banking", card_payment).find(id)[:tags]
  end

  let(:runtime) { boot_banking.tap { |booted| open_account(booted) } }

  it "hydrates tags into real Value instances, not raw Hashes", :aggregate_failures do
    authorize(runtime, "auth-1", [{ value: "high_risk" }, { value: "urgent" }])

    tags = stored_tags(runtime, "auth-1")
    expect(tags).to all(be_a(Hecks::Runtime::Value))
    expect(tags.map { |t| t[:value] }).to eq(["high_risk", "urgent"])
  end

  it "now enforces Tag's own pattern/invariant on a bare-sets tags argument" do
    expect { authorize(runtime, "auth-2", [{ value: "" }]) }.to raise_error(Hecks::Runtime::TypeMismatch)
  end

  it "still answers the Flagged named query (contains? tolerates real Value elements same as Hashes)" do
    authorize(runtime, "auth-1", [{ value: "high_risk" }])

    flagged = runtime.query("Banking::CardPayment.Flagged")
    expect(flagged.map { |r| r[:authorisation][:value] }).to eq(["auth-1"])
  end
end
