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
    runtime.dispatch("Wire::Drawer.Open", number: { value: "a" })
    runtime.dispatch("Wire::Drawer.Open", number: { value: "b" })
  end

  it "is refused, and says what to send instead" do
    expect do
      runtime.dispatch("Wire::Wire.Ask", reference: { value: "w1" }, amount: { cents: 100 },
                                         source: { value: "a" }, destination: "b")
    end.to raise_error(Hecks::Runtime::TypeMismatch,
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
    end.to raise_error(Hecks::Runtime::TypeMismatch, /and source arrived as an object/)
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

  # BUG#27 (QualityControl ledger) — found live on qa/stress_domains/
  # referral_chain's Member.Join/Referral.Issue: a bare Boolean, Array, or
  # `null` used to sail past this refusal entirely (only Hash/Value ever
  # matched it), get `.to_s`'d into a lookup key by `CommandRules::
  # References#reference_key` ("true", "false", "[8, 8]"), and answer
  # NotFound — or, for `null`, skip the lookup outright (`next if
  # held.nil?`, command_rules/references.rb) and answer whatever the
  # command's own `given` said instead (GivenNotMet here — "a wire moves
  # something" never even reaches `amount`). Rust's generated `from_json`
  # has always required a JSON string for a required reference field
  # before anything else runs — these four pin Ruby refusing the SAME
  # kind, at the SAME step (`normalize_args`, before `resolve_references`
  # ever gets a value to look up), matching it.
  describe "a non-string, non-object reference argument" do
    {
      "a bare Boolean (false)" => false,
      "a bare Boolean (true)"  => true,
      "a bare Array"           => [8, 8]
    }.each do |description, malformed|
      it "refuses #{description} as a wrong shape, not a lookup" do
        expect do
          runtime.dispatch("Wire::Wire.Ask", reference: { value: "w3" }, amount: { cents: 100 },
                                              source: malformed, destination: "b")
        end.to raise_error(Hecks::Runtime::TypeMismatch,
                           "Ask refused — a reference is an id, and source arrived as " \
                           "#{malformed.is_a?(Array) ? malformed.to_json : malformed} (Drawer is known by number)")
      end
    end

    it "refuses a REQUIRED reference offered as null, rather than reaching the command's own given" do
      expect do
        runtime.dispatch("Wire::Wire.Ask", reference: { value: "w4" }, amount: { cents: 100 },
                                            source: nil, destination: "b")
      end.to raise_error(Hecks::Runtime::TypeMismatch,
                         "Ask refused — a reference is an id, and source arrived as nil (Drawer is known by number)")
    end
  end

  # THE OTHER HALF OF THE JUDGMENT — an OPTIONAL command-level reference
  # (`reference_to ..., optional: true`) still passes an explicit `null`
  # straight through untouched: the caller genuinely may have nothing to
  # name yet (`Improvement.Open`'s own `reference_to Angle, optional:
  # true`, qa/bluebook/quality_control.bluebook), and BUG#27's fix is
  # scoped to a REQUIRED reference's own wrong shapes, not to this case.
  describe "an optional reference argument" do
    # NOT `HOP_CHAIN` — `spec/runtime/query_hop_spec.rb` already owns that
    # top-level name for the identical fixture path, and `load_hygiene_
    # spec.rb` refuses two spec files disagreeing about (or merely
    # duplicating) a top-level constant.
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
        hop_chain_runtime.dispatch("HopChain::Proposal.Draft", number: { value: "p1" }, engagement: nil)
      end.not_to raise_error
    end

    it "still refuses a wrong NON-NULL shape on that same optional reference" do
      expect do
        hop_chain_runtime.dispatch("HopChain::Proposal.Draft", number: { value: "p2" }, engagement: false)
      end.to raise_error(Hecks::Runtime::TypeMismatch,
                         "Draft refused — a reference is an id, and engagement arrived as false " \
                         "(Engagement is known by reference)")
    end
  end

  # AN ASK'S REFERENCE IS AN ID TOO, and this one closes a real split rather
  # than a hypothetical: one query path once opened a wrapped reference and
  # answered, while another read it whole and found nothing. Only a stale caller
  # would show it, which is exactly the kind of divergence that waits.
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

    it "is refused by the query's own name" do
      banking = boot_banking
      banking.dispatch("Banking::Customer.Register", reference: { value: "c" },
                       name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })

      expect { banking.query("Banking.customer_portfolio", customer: { value: "c" }) }
        .to raise_error(Hecks::Runtime::TypeMismatch,
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
