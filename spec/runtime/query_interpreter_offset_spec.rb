require "spec_helper"

# QueryInterpreter#interpret/#reference_interpret never read declared.offset
# — confirmed by grep returning nothing before this fix. Latent because the
# adapter-backed path (Ports::Query::InMemory, fixed by PR #324-326) already
# applied offset correctly; this is the OTHER path, native-vs-REFERENCE
# (runtime.query vs runtime.reference_query, the fuzzer's own oracle
# comparison in query_answers_match_reference), which took no adapter at all
# and went straight through this file instead. ATMCard.ByFee (`limit 3;
# offset 1`) is real corpus, not a synthetic fixture.
RSpec.describe "QueryInterpreter applies offset" do
  OFFSET_BANKING = File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook")

  def boot_banking
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(OFFSET_BANKING)
      Hecksagain::Runtime::Loader.bind_runtime(
        Hecksagain::Runtime::Dispatcher.new(registry)
      )
    end
  end

  # FOUR ACTIVE CARDS, DISTINCT FEES — `limit 3, offset 1` over four rows
  # ordered by fee names rows 2-4 ($2, $3, $4), never row 1 ($1) and never
  # nothing. Offset silently vanishing (the bug) would have answered rows
  # 1-3 instead — a page that starts one row too early, indistinguishable
  # from a fencepost mistake unless you already know the right answer.
  def four_cards(runtime)
    runtime.dispatch("Banking::Customer.Register", reference: { value: "c" },
                     name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
    runtime.dispatch("Banking::Account.Open", customer: "c", number: { value: "a1" },
                                              kind: { name: "current" }, daily_limit: { cents: 50_000 })
    %w[s1 s2 s3 s4].each_with_index do |serial, i|
      runtime.dispatch("Banking::ATMCard.Issue", account: "a1", serial: { value: serial },
                                                 daily_fee: { amount: (i + 1) * 1.0 })
      runtime.dispatch("Banking::ATMCard.Activate", serial: { value: serial })
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

  it "native and reference agree, exactly what query_answers_match_reference asserts" do
    runtime = boot_banking
    four_cards(runtime)

    native    = runtime.query("Banking::ATMCard.ByFee").map { |r| r[:serial].to_h }
    reference = runtime.reference_query("Banking::ATMCard.ByFee").map { |r| r[:serial].to_h }
    expect(native).to eq(reference)
  end
end
