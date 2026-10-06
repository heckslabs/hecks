require "spec_helper"

# `corrects` runtime facts that need a real dispatch: the `NothingToCorrect` refusal and
# `reverses: true` auto-deriving the corrective `sets` (DSL parsing is in spec/dsl_spec.rb).
RSpec.describe "a command's corrects" do
  # The correct/reverse cycle: a deposit, and a corrective command with no `as:` binding.
  CORRECTS_SMOKE_DOMAIN = proc do
    vision "Sanity check for the corrects command word."
    core

    aggregate "Box" do
      identified_by :number

      attribute :number,  Number
      attribute :balance, Money, default: { cents: 0 }

      value_object("Number") { attribute :value, String }
      value_object("Money")  { attribute :cents, Integer }

      command "Open" do
        role "Teller"
        attribute :number, Number
        emits "Opened"
      end

      command "Deposit" do
        role "Teller"
        reference_to Box
        attribute :amount, Money
        sets :balance, increment: :amount
        emits "Deposited"
      end

      command "ReverseDeposit" do
        role "Compliance officer"
        reference_to Box

        corrects "Deposited", reason: "duplicate debit, bank error"

        given("the balance covers the reversal") { balance.cents >= 500 }

        sets :balance, decrement: { cents: 500 }
        emits "DepositCorrected"
      end
    end
  end

  # The same aggregate with `reverses: true`, so the inverse mutation is derived.
  CORRECTS_AUTO_DOMAIN = proc do
    vision "Sanity check for corrects reverses: true structural auto-derivation."
    core

    aggregate "Box" do
      identified_by :number

      attribute :number,  Number
      attribute :balance, Money, default: { cents: 0 }

      value_object("Number") { attribute :value, String }
      value_object("Money")  { attribute :cents, Integer }

      command "Open" do
        role "Teller"
        attribute :number, Number
        emits "Opened"
      end

      command "Deposit" do
        role "Teller"
        reference_to Box
        attribute :amount, Money
        sets :balance, increment: :amount
        emits "Deposited"
      end

      command "ReverseDeposit" do
        role "Compliance officer"
        reference_to Box
        attribute :amount, Money
        corrects "Deposited", reason: "duplicate debit, bank error", reverses: true
        emits "DepositCorrected"
      end
    end
  end

  # Binds the as: name and reads it from both given and ensures in one dispatch.
  CORRECTS_AS_DOMAIN = proc do
    vision "corrects' own as: binds the located event for given/ensures to read."
    core

    aggregate "Box" do
      identified_by :number

      attribute :number,  Number
      attribute :balance, Money, default: { cents: 0 }

      value_object("Number") { attribute :value, String }
      value_object("Money")  { attribute :cents, Integer }

      command "Open" do
        role "Teller"
        attribute :number, Number
        emits "Opened"
      end

      command "Deposit" do
        role "Teller"
        reference_to Box
        attribute :amount, Money
        sets :balance, increment: :amount
        emits "Deposited"
      end

      # `as: :original` binds the located "Deposited" payload; a `given` (refuses a wrong
      # amount) and an `ensures` (balance restored) read `original.amount.cents`.
      command "ReverseDeposit" do
        role "Compliance officer"
        reference_to Box
        attribute :amount, Money

        corrects "Deposited", as: :original, reason: "duplicate debit, bank error"

        given("the reversal names the exact amount originally deposited") { amount.cents == original.amount.cents }
        ensures("the balance no longer reflects the original deposit") { balance.cents != old.balance.cents }
        ensures("the amount corrected still names the exact original event") { original.amount.cents == amount.cents }

        sets :balance, decrement: :amount
        emits "DepositCorrected"
      end
    end
  end

  # `corrects` on an entity-level command must not crash with WiringError. `Ledger.Record`
  # (aggregate) emits "EntryRecorded"; `Entry.Amend` (entity) corrects it, because an entity has
  # no event stream and admissibility is checked against the parent record's history.
  # `Ledger.Import` adds an Entry without emitting it, so the refusal case uses a separate ledger
  # whose history never announced the event.
  CORRECTS_ENTITY_DOMAIN = proc do
    vision "Sanity check for corrects declared on an entity-level command."
    core

    aggregate "Ledger" do
      identified_by :reference

      attribute :reference, Reference
      attribute :entries,   list_of(Entry)

      value_object("Reference")     { attribute :value, String }
      value_object("Amount")        { attribute :cents, Integer }
      value_object("EntrySequence") { attribute :value, Integer }

      command "Open" do
        role "Clerk"
        attribute :reference, Reference
        emits "Opened"
      end

      command "Record" do
        role "Clerk"
        reference_to Ledger
        attribute :amount, Amount
        sets :entries, append: { amount: :amount }
        emits "EntryRecorded"
      end

      # Never emits "EntryRecorded"; the refusal fixture's entry arrives here.
      command "Import" do
        role "Clerk"
        reference_to Ledger
        attribute :amount, Amount
        sets :entries, append: { amount: :amount }
        emits "EntryImported"
      end

      entity "Entry" do
        identified_by :sequence

        attribute :sequence, EntrySequence
        attribute :amount,   Amount

        # `as: :original` is bound and read from given and ensures, as in the aggregate one.
        command "Amend" do
          role "Auditor"
          attribute :amount, Amount

          corrects "EntryRecorded", as: :original, reason: "an entry amount was mis-keyed"

          given("the amendment names a different amount than originally recorded") do
            amount.cents != original.amount.cents
          end
          ensures("the amount changed") { amount.cents != old.amount.cents }
          # `original` is readable from ensures too, not just given.
          ensures("the settled amount still differs from the original event it corrects") do
            amount.cents != original.amount.cents
          end

          sets :amount
          emits "EntryAmended"
        end
      end
    end
  end

  # Build-time refusal: the raise is the point; the inline domain makes the lossy op concrete.
  CORRECTS_LOSSY_DOMAIN = proc do
    vision "reverses: true must refuse against a lossy original op."
    core

    aggregate "Box" do
      identified_by :number
      attribute :number,  Number
      attribute :balance, Money, default: { cents: 0 }

      value_object("Number") { attribute :value, String }
      value_object("Money")  { attribute :cents, Integer }

      command "Open" do
        role "Teller"
        attribute :number, Number
        emits "Opened"
      end

      command "Overwrite" do
        role "Teller"
        reference_to Box
        attribute :amount, Money
        sets :balance, to: :amount
        emits "Overwritten"
      end

      command "ReverseOverwrite" do
        role "Compliance officer"
        reference_to Box
        corrects "Overwritten", reason: "wrong amount", reverses: true
        emits "OverwriteCorrected"
      end
    end
  end

  def boot_corrects(name, body)
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Hecks.bluebook(name, &body)
    end

    Hecks::Runtime::Dispatcher.new(registry)
  end

  def box(verb, number = "b-1", **args)
    dispatcher.dispatch_flat("#{domain}::Box.#{verb}", number: { value: number }, **args)
  end

  def cents(amount) = { amount: { cents: amount } }

  describe "a full correct/reverse cycle" do
    let(:domain) { "CorrectsSmoke" }
    let(:dispatcher) { boot_corrects(domain, CORRECTS_SMOKE_DOMAIN) }

    before do
      box("Open")
      box("Open", "b-2")
    end

    it "reverses a deposit through the corrective command" do
      deposited = box("Deposit", **cents(1000)).instance.balance.cents
      reversed  = box("ReverseDeposit").instance.balance.cents

      expect([deposited, reversed]).to eq([1000, 500])
    end

    it "refuses correction against a record that was never corrected" do
      expect { box("ReverseDeposit", "b-2") }.to raise_error(Hecks::Runtime::NothingToCorrect)
    end

    it "logs the opens, the deposit, and the correction in order" do
      box("Deposit", **cents(1000))
      box("ReverseDeposit")

      expect(dispatcher.registry.event_log.map(&:name)).to eq(["Opened", "Opened", "Deposited", "DepositCorrected"])
    end
  end

  describe "reverses: true" do
    let(:domain) { "CorrectsAutoSmoke" }
    let(:dispatcher) { boot_corrects(domain, CORRECTS_AUTO_DOMAIN) }

    it "auto-derives the inverse mutation for reverses: true" do
      box("Open")
      box("Deposit", **cents(1000))

      expect(box("ReverseDeposit", **cents(1000)).instance.balance.cents).to eq(0)
    end

    it "refuses at build time when the original used a lossy op" do
      expect { Hecks.bluebook("CorrectsLossySmoke", &CORRECTS_LOSSY_DOMAIN) }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /not statically invertible/)
    end
  end

  describe "as:" do
    let(:domain) { "CorrectsAsSmoke" }
    let(:dispatcher) { boot_corrects(domain, CORRECTS_AS_DOMAIN) }

    it "binds corrects' own as: name to the located event's payload, readable from given and ensures",
       :aggregate_failures do
      box("Open")
      box("Deposit", **cents(1000))

      expect { box("ReverseDeposit", **cents(999)) }.to raise_error(Hecks::Runtime::GivenNotMet)
      expect(box("ReverseDeposit", **cents(1000)).instance.balance.cents).to eq(0)
    end
  end

  describe "on an entity-level command" do
    let(:dispatcher) { boot_corrects("EntityCorrectsSmoke", CORRECTS_ENTITY_DOMAIN) }

    def ledger(verb, reference, **args)
      dispatcher.dispatch_flat("EntityCorrectsSmoke::Ledger.#{verb}", reference: { value: reference }, **args)
    end

    def amend_entry(reference, amount) = ledger("Entry.Amend", reference, sequence: { value: 1 }, amount: { cents: amount })

    def record_entry(reference)
      ledger("Open", reference)
      ledger("Record", reference, amount: { cents: 1000 })
    end

    def import_entry(reference)
      ledger("Open", reference)
      ledger("Import", reference, amount: { cents: 2000 })
    end

    # Legitimate: l-1's entry targets an already-emitted "EntryRecorded"; dispatches cleanly.
    it "dispatches cleanly against an entry whose ledger recorded the event" do
      record_entry("l-1")
      amended = amend_entry("l-1", 1500)

      entry = amended.instance.entries.find { |e| e[:sequence].value == 1 }
      expect(entry[:amount].cents).to eq(1500)
    end

    # Illegitimate: l-2's history never emitted "EntryRecorded"; refuses with NothingToCorrect.
    it "refuses cleanly (not crashing) against an entry whose ledger never recorded it" do
      import_entry("l-2")

      expect { amend_entry("l-2", 500) }.to raise_error(Hecks::Runtime::NothingToCorrect)
    end

    it "logs only the events the ledgers really announced" do
      record_entry("l-1")
      import_entry("l-2")
      amend_entry("l-1", 1500)

      expect(dispatcher.registry.event_log.map(&:name)).to eq(%w[Opened EntryRecorded Opened EntryImported EntryAmended])
    end
  end
end
