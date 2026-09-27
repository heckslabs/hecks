require "spec_helper"

# The in-memory interpreter path (runtime.query vs runtime.reference_query, the fuzzer's
# oracle) applies a declared offset. ATMCard.ByFee (`limit 3; offset 1`) is real corpus.
RSpec.describe "QueryInterpreter applies offset" do
  OFFSET_BANKING = InMemoryDomain::BANKING_BLUEBOOK_DIR

  def boot_banking
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(OFFSET_BANKING)
      Hecks::Runtime::Loader.bind_runtime(
        Hecks::Runtime::Dispatcher.new(registry)
      )
    end
  end

  # Four active cards with distinct fees: `limit 3, offset 1` must answer rows 2-4.
  def four_cards(runtime)
    runtime.dispatch_flat("Banking::Customer.Register", reference: { value: "c" },
                     name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
    runtime.dispatch_flat("Banking::Account.Open", customer: "c", number: { value: "a1" },
                                              kind: { name: "current" }, daily_limit: { cents: 50_000 })
    %w[s1 s2 s3 s4].each_with_index do |serial, i|
      runtime.dispatch_flat("Banking::ATMCard.Issue", account: "a1", serial: { value: serial },
                                                 daily_fee: { amount: (i + 1) * 1.0 })
      runtime.dispatch_flat("Banking::ATMCard.Activate", serial: { value: serial })
    end
  end

  it "native runtime.query skips before it takes" do
    runtime = boot_banking
    four_cards(runtime)

    rows = runtime.query("Banking::ATMCard.ByFee")
    expect(rows.map { |r| r[:serial].to_h }).to eq([{ value: "s2" }, { value: "s3" }, { value: "s4" }])
  end

  it "reference_query — the fuzzer's own oracle path — skips before it takes too" do
    runtime = boot_banking
    four_cards(runtime)

    rows = runtime.reference_query("Banking::ATMCard.ByFee")
    expect(rows.map { |r| r[:serial].to_h }).to eq([{ value: "s2" }, { value: "s3" }, { value: "s4" }])
  end
end
