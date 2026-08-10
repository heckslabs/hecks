
require "spec_helper"
require "tmpdir"

# where/order_by/limit/offset used to be accepted by a read_model's DSL
# and silently ignored by every interpreter — a declared filter that
# never filtered, an order that was always id order regardless. This
# holds the fix: the options apply to the one many-side collection they
# can unambiguously mean, on both the in-memory path (Memory, and
# Postgres, which has no native read-model hook) and Sqlite's own
# projected-table path — proven against the real corpus:
# `ComplianceDashboard` (where/order_by/limit, extended this session
# specifically to cover this) and `CustomerPortfolio` (no options
# declared at all, the "leaves it exactly as before" control).
RSpec.describe "a read model's query options" do
  def build(adapter: "Memory")
    registry = Hecksagain::Runtime::Registry.new
    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook"))
      Hecks.hecksagon("Banking") do
        Banking::Customer.persisted_by(adapter)
        Banking::Account.persisted_by(adapter)
        Banking::ATMCard.persisted_by(adapter)
        Banking::Transfer.persisted_by(adapter)
        Banking::CardPayment.persisted_by(adapter)
        Banking::ExternalTransfer.persisted_by(adapter)
        Banking::ScheduledPayment.persisted_by(adapter)
        Banking::SafeDepositBox.persisted_by(adapter)
        Banking::OnboardingCase.persisted_by(adapter)
      end
      yield if block_given?
    end
    registry.verify!
    Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
  end

  # SIX disputed amounts — one more than ComplianceDashboard's `limit 5` —
  # so the cap actually trims something, not just fits everything given.
  # A seventh, undisputed payment proves `where(status: "disputed")`
  # actually filters, not just "everything CardPayment holds".
  DISPUTED_AMOUNTS = [100, 600, 300, 500, 200, 400].freeze

  def seed_disputed_card_payments
    Banking::Customer.register(reference: { value: "c1" }, name: { given: "A", family: "B" },
                                email: { address: "a@example.com" })
    Banking::Account.open(customer_id: "c1", number: { value: "acct-1" },
                           kind: { name: "current" }, daily_limit: { cents: 10_000 })

    DISPUTED_AMOUNTS.each_with_index do |cents, index|
      pay = Banking::CardPayment.authorize(account_id: "acct-1", authorisation: { value: "auth-#{index}" },
                                            amount: { cents: cents }, merchant: { value: "Shop#{index}" })
      pay.capture
      pay.dispute(disputed_by: "c1")
    end

    Banking::CardPayment.authorize(account_id: "acct-1", authorisation: { value: "auth-undisputed" },
                                    amount: { cents: 999 }, merchant: { value: "Undisputed Shop" })
  end

  it "filters, orders, and caps the one many-side collection" do
    runtime = build
    seed_disputed_card_payments

    rows = runtime.query("Banking.compliance_dashboard", account: "acct-1")
    payments = rows.first[:card_payments]

    expect(payments.map { |p| p[:amount][:cents] }).to eq([600, 500, 400, 300, 200])
  end

  it "refuses at build with zero many-side heads" do
    expect do
      registry = Hecksagain::Runtime::Registry.new
      Hecksagain.with_registry(registry) do
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Hecks.bluebook("Solitary") do
          vision "x"
          generic

          aggregate "Account" do
            identified_by { ref.value }
            attribute :ref, Ref
            value_object "Ref" do
              attribute :value, String
            end
          end

          read_model "Solo" do
            reference_to Account
            include Account
            where(ref: "a1")
          end
        end
      end
    end.to raise_error(Hecksagain::Bluebook::DSL::Malformed, /includes 0 many-side aggregates, not exactly one/)
  end

  it "refuses at build with more than one many-side head" do
    expect do
      registry = Hecksagain::Runtime::Registry.new
      Hecksagain.with_registry(registry) do
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Hecks.bluebook("Crowded") do
          vision "x"
          generic

          aggregate "Account" do
            identified_by { ref.value }
            attribute :ref, Ref
            value_object "Ref" do
              attribute :value, String
            end
          end

          aggregate "Entry" do
            identified_by { ref.value }
            attribute :ref, Ref
            reference_to Account, as: :account
            value_object "Ref" do
              attribute :value, String
            end
          end

          aggregate "Note" do
            identified_by { ref.value }
            attribute :ref, Ref
            reference_to Account, as: :account
            value_object "Ref" do
              attribute :value, String
            end
          end

          read_model "Both" do
            reference_to Account
            include Account
            include Entry
            include Note
            limit 1
          end
        end
      end
    end.to raise_error(Hecksagain::Bluebook::DSL::Malformed, /includes 2 many-side aggregates, not exactly one/)
  end

  it "leaves a read model with no declared options exactly as before" do
    runtime = build
    seed_disputed_card_payments

    rows = runtime.query("Banking.customer_portfolio", customer: "c1")
    expect(rows.first[:card_payments].map { |p| p[:amount][:cents] })
      .to contain_exactly(100, 600, 300, 500, 200, 400, 999)
  end

  # ADVERSARIAL, not incidental: read_model_builder.rb's own `include`
  # comment says this is "Order-independent" — the `:many` flag really
  # is, resolved at build time once @reference_target is known. The
  # JOIN never was: this loop used to match a many-side head against
  # whatever was already accumulated in `projected`, which is empty
  # the very first time through — so a many-side head declared BEFORE
  # the root silently returned an empty array, no error, just a
  # wrong, too-small answer. Every real corpus read model (both of
  # Banking's) happens to declare its root first, so this never
  # surfaced there; caught only by deliberately reversing the order.
  it "joins the many side correctly regardless of which order include declares it and the root in" do
    build_reversed = lambda do
      registry = Hecksagain::Runtime::Registry.new
      Hecksagain.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Hecks.bluebook("Reordered") do
          vision "x"
          generic

          aggregate "Item" do
            identified_by { name.value }
            attribute :name, Name
            value_object "Name" do
              attribute :value, String
            end
            command "Add" do
              attribute :name, Name
              then_set :name, to: :name
            end
          end

          aggregate "Promotion" do
            identified_by { ref.value }
            attribute :ref, Ref
            reference_to Item, as: :item
            value_object "Ref" do
              attribute :value, String
            end
            command "Promote" do
              attribute :ref, Ref
              reference_to Item
              then_set :ref, to: :ref
              then_set :item, to: :item_id
            end
          end

          # THE MANY SIDE DECLARED FIRST — the exact ordering that
          # broke, deliberately, not the accidentally-working order
          # every real corpus read model happens to use.
          read_model "Search" do
            reference_to Item
            include Promotion
            include Item
          end
        end
        Hecks.hecksagon("Reordered") do
          Reordered::Item.persisted_by("Memory")
          Reordered::Promotion.persisted_by("Memory")
        end
      end
      registry.verify!
      Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
    end

    runtime = build_reversed.call
    Reordered::Item.add(name: { value: "headlamp" })
    Reordered::Promotion.promote(ref: { value: "p1" }, item_id: "headlamp")

    rows = runtime.query("Reordered.search", item: "headlamp")

    expect(rows.first[:item][:id]).to eq("headlamp")
    expect(rows.first[:promotions].map { |p| p[:id] }).to eq(["p1"])
  end

  it "applies the same options through Sqlite's native projected-table path" do
    Dir.mktmpdir do |dir|
      registry = Hecksagain::Runtime::Registry.new
      Hecksagain.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecksagain/adapters/driven/sqlite.adapter"))
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Kernel.load(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook"))
        Hecks.hecksagon("Banking") do
          Banking::Customer.persisted_by("SqlitePersistence")
          Banking::Account.persisted_by("SqlitePersistence")
          Banking::CardPayment.persisted_by("SqlitePersistence")
        end
        Hecks.world("Banking") do
          persisted_by("SqlitePersistence") { database File.join(dir, "banking.db") }
        end
      end
      registry.verify!
      runtime = Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))

      seed_disputed_card_payments

      rows = runtime.query("Banking.compliance_dashboard", account: "acct-1")
      expect(rows.first[:card_payments].map { |p| p[:amount][:cents] }).to eq([600, 500, 400, 300, 200])
    end
  end
end
