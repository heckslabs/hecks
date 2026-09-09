require "spec_helper"

# ADR 0047 — regression coverage against the REAL, shipped corpus command
# the bug was traced against (`Banking::CardPayment.Authorize`'s own bare
# `sets :tags`, `list_of(Tag)`), not just the synthetic fixture in
# spec/runtime/entity_list_mutations_spec.rb. Deliberately its own file,
# not folded into an existing one — spec/runtime/entity_list_mutations_
# spec.rb's own header already names the real gotcha with a bare
# top-level constant reused across files, so this one names nothing bare
# at all, reaching `InMemoryDomain::BANKING_BLUEBOOK_DIR` directly.
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

  it "hydrates tags into real Value instances, not raw Hashes" do
    runtime = boot_banking
    runtime.dispatch("Banking::Customer.Register", reference: { value: "c1" },
                     name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
    runtime.dispatch("Banking::Account.Open", customer: "c1", number: { value: "a1" },
                                              kind: { name: "current" }, daily_limit: { cents: 1_000 })
    runtime.dispatch("Banking::CardPayment.Authorize", account: "a1", authorisation: { value: "auth-1" },
                                                        amount: { cents: 500 }, merchant: { value: "Shop" },
                                                        tags: [{ value: "high_risk" }, { value: "urgent" }])

    tags = runtime.registry.repository("Banking", runtime.registry.bluebook("Banking").aggregate("CardPayment"))
                  .find("auth-1")[:tags]
    expect(tags).to all(be_a(Hecks::Runtime::Value))
    expect(tags.map { |t| t[:value] }).to eq(["high_risk", "urgent"])
  end

  it "now enforces Tag's own pattern/invariant on a bare-sets tags argument" do
    runtime = boot_banking
    runtime.dispatch("Banking::Customer.Register", reference: { value: "c1" },
                     name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
    runtime.dispatch("Banking::Account.Open", customer: "c1", number: { value: "a1" },
                                              kind: { name: "current" }, daily_limit: { cents: 1_000 })

    expect do
      runtime.dispatch("Banking::CardPayment.Authorize", account: "a1", authorisation: { value: "auth-2" },
                                                          amount: { cents: 500 }, merchant: { value: "Shop" },
                                                          tags: [{ value: "" }])
    end.to raise_error(Hecks::Runtime::TypeMismatch)
  end

  it "still answers the Flagged named query (contains? tolerates real Value elements same as Hashes)" do
    runtime = boot_banking
    runtime.dispatch("Banking::Customer.Register", reference: { value: "c1" },
                     name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
    runtime.dispatch("Banking::Account.Open", customer: "c1", number: { value: "a1" },
                                              kind: { name: "current" }, daily_limit: { cents: 1_000 })
    runtime.dispatch("Banking::CardPayment.Authorize", account: "a1", authorisation: { value: "auth-1" },
                                                        amount: { cents: 500 }, merchant: { value: "Shop" },
                                                        tags: [{ value: "high_risk" }])

    flagged = runtime.query("Banking::CardPayment.Flagged")
    expect(flagged.map { |r| r[:authorisation][:value] }).to eq(["auth-1"])
  end
end
