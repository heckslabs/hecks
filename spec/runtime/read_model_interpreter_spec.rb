require "spec_helper"
require "tmpdir"
require "json"

# where/order_by/limit/offset apply to a read model's one many-side
# collection, honored identically by the in-memory (Memory, Postgres),
# and Sqlite projected-table interpreter paths.
RSpec.describe "a read model's query options" do
  def build(adapter: "Memory")
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
      Hecks.hecksagon("Banking") do
        attaches "Governance"
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
      Hecks.hecksagon("Governance") do
        Governance::RoleAssignment.persisted_by("Memory")
        Governance::RoleTransition.persisted_by("Memory")
      end
      yield if block_given?
    end
    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  # Adds a second read model to the already-loaded Banking domain from Ruby,
  # not a file under `examples/banking/bluebook/` — rust/parser doesn't yet
  # recognize `on:` and would misparse it.
  def build_with_targeted_read_model(adapter: "Memory")
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
      Hecks.bluebook("Banking") do
        read_model "MultiTarget" do
          reference_to Account
          include Account
          include CardPayment
          include ATMCard

          where(status: "disputed", on: CardPayment)
        end
      end
      Hecks.hecksagon("Banking") do
        attaches "Governance"
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
      Hecks.hecksagon("Governance") do
        Governance::RoleAssignment.persisted_by("Memory")
        Governance::RoleTransition.persisted_by("Memory")
      end
    end
    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  # Eleven disputed amounts: two full pages of 5 plus one left over, so the
  # cap trims something on each page, not just the first. A twelfth,
  # undisputed payment proves `where(status: "disputed")` actually filters.
  DISPUTED_AMOUNTS = [100, 600, 300, 500, 200, 400, 150, 550, 250, 450, 50].freeze

  def seed_disputed_card_payments
    Banking::Customer.register!(reference: { value: "c1" }, name: { given: "A", family: "B" },
                                email: { address: "a@example.com" })
    Banking::Account.open!(customer: "c1", number: { value: "acct-1" },
                           kind: { name: "current" }, daily_limit: { cents: 10_000 })

    DISPUTED_AMOUNTS.each_with_index do |cents, index|
      pay = Banking::CardPayment.authorize!(account: "acct-1", authorisation: { value: "auth-#{index}" },
                                            amount: { cents: cents }, merchant: { value: "Shop#{index}" })
      pay.capture!
      pay.dispute!(disputed_by: "c1")
    end

    Banking::CardPayment.authorize!(account: "acct-1", authorisation: { value: "auth-undisputed" },
                                    amount: { cents: 999 }, merchant: { value: "Undisputed Shop" })
  end

  it "filters, orders, and caps the one many-side collection" do
    runtime = build
    seed_disputed_card_payments

    rows = runtime.query("Banking.compliance_dashboard", account: "acct-1")
    payments = rows.first[:card_payments]

    # `offset 5` skips the first page — still ordered and capped at 5.
    expect(payments.map { |p| p[:amount][:cents] }).to eq([300, 250, 200, 150, 100])
  end

  it "refuses at build with zero many-side heads" do
    expect do
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Hecks.bluebook("Solitary") do
          vision "x"
          generic

          aggregate "Account" do
            identified_by :ref
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
    end.to raise_error(Hecks::Bluebook::DSL::Malformed, /includes 0 many-side aggregates, not exactly one/)
  end

  # The inline three-aggregate domain is the fixture for this refusal;
  # trimming it would lose the "more than one many-side head" shape.
  # rubocop:disable-next RSpec/ExampleLength
  it "refuses at build with more than one many-side head" do
    expect do
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Hecks.bluebook("Crowded") do
          vision "x"
          generic

          aggregate "Account" do
            identified_by :ref
            attribute :ref, Ref
            value_object "Ref" do
              attribute :value, String
            end
          end

          aggregate "Entry" do
            identified_by :ref
            attribute :ref, Ref
            reference_to Account, as: :account
            value_object "Ref" do
              attribute :value, String
            end
          end

          aggregate "Note" do
            identified_by :ref
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
    end.to raise_error(Hecks::Bluebook::DSL::Malformed, /includes 2 many-side aggregates, not exactly one/)
  end

  # `on:` naming an aggregate that isn't a many-side head is a real typo
  # shape, distinct from omitting `on:` entirely. `Account` is the root, a
  # single row, so it can never be a legal target regardless of head count.
  # rubocop:disable-next RSpec/ExampleLength
  it "refuses `on:` that doesn't name one of its own many-side aggregates" do
    expect do
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Hecks.bluebook("Mistargeted") do
          vision "x"
          generic

          aggregate "Account" do
            identified_by :ref
            attribute :ref, Ref
            value_object "Ref" do
              attribute :value, String
            end
          end

          aggregate "Entry" do
            identified_by :ref
            attribute :ref, Ref
            reference_to Account, as: :account
            value_object "Ref" do
              attribute :value, String
            end
          end

          aggregate "Note" do
            identified_by :ref
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

            where(ref: "a1", on: Account)
          end
        end
      end
    end.to raise_error(Hecks::Bluebook::DSL::Malformed, /doesn't name one of its own many-side included aggregates/)
  end

  # `on:` names which many-side head query options target when a read
  # model includes more than one; `CardPayment` is filtered while `ATMCard`,
  # with no `on:` of its own, comes back whole.
  #
  # Declared here in Ruby, not under `examples/banking/bluebook/`, because
  # `rust/parser` doesn't yet recognize `on:` and would misparse it as an
  # ordinary where-field.
  it "filters one many-side collection with `on:`, leaving another untouched" do
    runtime = build_with_targeted_read_model
    seed_disputed_card_payments
    Banking::ATMCard.issue!(account: "acct-1", serial: { value: "card-1" }, daily_fee: { amount: 0.0 })
    Banking::ATMCard.issue!(account: "acct-1", serial: { value: "card-2" }, daily_fee: { amount: 0.0 })

    rows = runtime.query("Banking.multi_target", account: "acct-1")

    expect(rows.first[:card_payments].map { |p| p[:amount][:cents] }.sort).to eq(DISPUTED_AMOUNTS.sort)
    expect(rows.first[:atm_cards].map { |c| c[:serial][:value] }.sort).to eq(%w[card-1 card-2])
  end

  it "leaves a read model with no declared options exactly as before" do
    runtime = build
    seed_disputed_card_payments

    rows = runtime.query("Banking.customer_portfolio", customer: "c1")
    expect(rows.first[:card_payments].map { |p| p[:amount][:cents] })
      .to contain_exactly(100, 600, 300, 500, 200, 400, 150, 550, 250, 450, 50, 999)
  end

  # Pins a real bug: the join matched a many-side head against whatever was
  # already accumulated, which is empty when that head is declared before
  # the root — a silent, wrong empty result, not an error. Every real
  # corpus read model happens to declare its root first, so only a
  # deliberately reordered domain catches this.
  # rubocop:disable-next RSpec/ExampleLength
  it "joins the many side correctly regardless of which order include declares it and the root in" do
    build_reversed = lambda do
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Hecks.bluebook("Reordered") do
          vision "x"
          generic

          aggregate "Item" do
            identified_by :name
            attribute :name, Name
            value_object "Name" do
              attribute :value, String
            end
            command "Add" do
              attribute :name, Name
              sets :name
            end
          end

          aggregate "Promotion" do
            identified_by :ref
            attribute :ref, Ref
            reference_to Item, as: :item
            value_object "Ref" do
              attribute :value, String
            end
            command "Promote" do
              attribute :ref, Ref
              reference_to Item
              sets :ref
              sets :item
            end
          end

          # The many side declared first — the ordering that broke.
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
      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    end

    runtime = build_reversed.call
    Reordered::Item.add!(name: { value: "headlamp" })
    Reordered::Promotion.promote!(ref: { value: "p1" }, item: "headlamp")

    rows = runtime.query("Reordered.search", item: "headlamp")

    expect(rows.first[:item][:id]).to eq("headlamp")
    expect(rows.first[:promotions].map { |p| p[:id] }).to eq(["p1"])
  end

  # Root-first alone doesn't reach a chain of non-root heads: Coupon
  # (which needs Promotion resolved) declared before Promotion, with the
  # root last, is the worst order for the old code and pins that a
  # dependency chain more than one level deep resolves correctly
  # regardless of declaration order.
  # rubocop:disable-next RSpec/ExampleLength
  it "joins a CHAIN of non-root heads correctly regardless of declaration order, not just one level deep" do
    build_chain = lambda do
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Hecks.bluebook("Chained") do
          vision "x"
          generic

          aggregate "Item" do
            identified_by :name
            attribute :name, Name
            value_object "Name" do
              attribute :value, String
            end
            command "Add" do
              attribute :name, Name
              sets :name
            end
          end

          aggregate "Promotion" do
            identified_by :ref
            attribute :ref, Ref
            reference_to Item, as: :item
            value_object "Ref" do
              attribute :value, String
            end
            command "Promote" do
              attribute :ref, Ref
              reference_to Item
              sets :ref
              sets :item
            end
          end

          # References Promotion, not the root — one level deeper than
          # root-first alone reaches.
          aggregate "Coupon" do
            identified_by :ref
            attribute :ref, Ref
            reference_to Promotion, as: :promotion
            value_object "Ref" do
              attribute :value, String
            end
            command "Issue" do
              attribute :ref, Ref
              reference_to Promotion
              sets :ref
              sets :promotion
            end
          end

          # Worst declaration order for the old code: deepest dependency
          # first, its own dependency second, root last.
          read_model "Search" do
            reference_to Item
            include Coupon
            include Promotion
            include Item
          end
        end
        Hecks.hecksagon("Chained") do
          Chained::Item.persisted_by("Memory")
          Chained::Promotion.persisted_by("Memory")
          Chained::Coupon.persisted_by("Memory")
        end
      end
      registry.verify!
      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    end

    runtime = build_chain.call
    Chained::Item.add!(name: { value: "headlamp" })
    Chained::Promotion.promote!(ref: { value: "p1" }, item: "headlamp")
    Chained::Coupon.issue!(ref: { value: "c1" }, promotion: "p1")

    rows = runtime.query("Chained.search", item: "headlamp")

    expect(rows.first[:item][:id]).to eq("headlamp")
    expect(rows.first[:promotions].map { |p| p[:id] }).to eq(["p1"])
    expect(rows.first[:coupons].map { |c| c[:id] }).to eq(["c1"])
  end

  # `include` also accepts a nested entity (declared with `entity` inside
  # an aggregate), not just a top-level aggregate. `bluebook.aggregate`
  # only searches top-level aggregates, so an entity head resolves to
  # nil; this pins that the ordering pass tolerates that (an empty result
  # for that head, not a crash) while a real dependency chain around it
  # still resolves correctly.
  # rubocop:disable-next RSpec/ExampleLength
  it "tolerates an included head that is a nested entity, not a top-level aggregate, without crashing" do
    build_entity_head = lambda do
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Hecks.bluebook("EntityHeaded") do
          vision "x"
          generic

          aggregate "Item" do
            identified_by :name
            attribute :name, Name
            attribute :notes, list_of(Note)
            value_object "Name" do
              attribute :value, String
            end
            value_object "NoteRef" do
              attribute :value, String
            end
            command "Add" do
              attribute :name, Name
              sets :name
            end

            # A nested entity, not a top-level aggregate — same shape as
            # Member/Handler/Dispatch elsewhere in the grammar.
            entity "Note" do
              identified_by :ref
              attribute :ref, NoteRef
            end
          end

          aggregate "Promotion" do
            identified_by :ref
            attribute :ref, Ref
            reference_to Item, as: :item
            value_object "Ref" do
              attribute :value, String
            end
            command "Promote" do
              attribute :ref, Ref
              reference_to Item
              sets :ref
              sets :item
            end
          end

          # Worst order for the resolvable chain, with the unresolvable
          # entity head mixed in first so a crash there would hide
          # whether ordering among the rest still works.
          read_model "Search" do
            reference_to Item
            include Note
            include Promotion
            include Item
          end
        end
        Hecks.hecksagon("EntityHeaded") do
          EntityHeaded::Item.persisted_by("Memory")
          EntityHeaded::Promotion.persisted_by("Memory")
        end
      end
      registry.verify!
      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    end

    runtime = build_entity_head.call
    EntityHeaded::Item.add!(name: { value: "headlamp" })
    EntityHeaded::Promotion.promote!(ref: { value: "p1" }, item: "headlamp")

    rows = runtime.query("EntityHeaded.search", item: "headlamp")

    expect(rows.first[:item][:id]).to eq("headlamp")
    expect(rows.first[:promotions].map { |p| p[:id] }).to eq(["p1"])
    # An entity head has no repository of its own to read from, so empty,
    # not a crash, is the correct current answer.
    expect(rows.first[:notes]).to eq([])
  end

  # Proves the same options apply against a real SQLite-backed store. No
  # `projected_by` is bound, so this exercises the in-process
  # `ReadModelInterpreter` path (`SqlitePersistence`), not
  # `SqliteProjection`'s native path — see the next example for that.
  # rubocop:disable-next RSpec/ExampleLength
  it "applies the same options through a real Sqlite-backed authoritative store (in-process path)" do
    Dir.mktmpdir do |dir|
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/sqlite.adapter"))
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
        Hecks.hecksagon("Banking") do
          attaches "Governance"
          Banking::Customer.persisted_by("SqlitePersistence")
          Banking::Account.persisted_by("SqlitePersistence")
          Banking::CardPayment.persisted_by("SqlitePersistence")
        end
        Hecks.hecksagon("Governance") do
          Governance::RoleAssignment.persisted_by("Memory")
          Governance::RoleTransition.persisted_by("Memory")
        end
        Hecks.world("Banking") do
          persisted_by("SqlitePersistence") { database File.join(dir, "banking.db") }
        end
      end
      registry.verify!
      runtime = Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))

      seed_disputed_card_payments

      # Confirms the claim above by construction: a stray `projected_by`
      # here would move this onto the native path silently instead of
      # failing loudly.
      account = registry.bluebook("Banking").aggregate("Account")
      repository = registry.read_repository("Banking", account)
      unless repository.adapter.is_a?(Hecks::Adapters::Sqlite) && !repository.adapter.is_a?(Hecks::Adapters::SqliteProjection)
        raise "expected the plain SqlitePersistence path, got #{repository.adapter.class}"
      end

      rows = runtime.query("Banking.compliance_dashboard", account: "acct-1")
      # `offset 5` — see the in-memory version of this same assertion above.
      expect(rows.first[:card_payments].map { |p| p[:amount][:cents] }).to eq([300, 250, 200, 150, 100])
    end
  end

  # The real native-path proof: exercises `SqliteProjection#query_read_model`
  # against a read model with real where/order_by/limit/offset, and
  # compares the native result against an independently-booted in-process
  # run fed the same seed, rather than a second hand-typed literal that
  # could drift the same wrong way.
  # rubocop:disable-next RSpec/ExampleLength
  it "agrees with the in-process path through Sqlite's real native projected-table path" do
    Dir.mktmpdir do |native_dir|
      native_registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(native_registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecks/ports/projection.port"))
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/sqlite.adapter"))
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
        Hecks.hecksagon("Banking") do
          attaches "Governance"
          Banking::Customer.persisted_by("SqlitePersistence")
          Banking::Account.persisted_by("SqlitePersistence")
          Banking::Account.projected_by("SqliteProjection")
          Banking::CardPayment.persisted_by("SqlitePersistence")
          Banking::CardPayment.projected_by("SqliteProjection")
        end
        Hecks.hecksagon("Governance") do
          Governance::RoleAssignment.persisted_by("Memory")
          Governance::RoleTransition.persisted_by("Memory")
        end
        Hecks.world("Banking") do
          persisted_by("SqlitePersistence") { database File.join(native_dir, "banking.db") }
          projected_by("SqliteProjection") { database File.join(native_dir, "banking-projection.db") }
        end
      end
      native_registry.verify!
      native_runtime = Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(native_registry))
      seed_disputed_card_payments

      %w[Account CardPayment].each do |name|
        aggregate = native_registry.bluebook("Banking").aggregate(name)
        Hecks::Ports::Projection.worker(native_registry, "Banking", aggregate)&.catch_up!
      end

      account = native_registry.bluebook("Banking").aggregate("Account")
      repository = native_registry.read_repository("Banking", account)
      unless repository.adapter.is_a?(Hecks::Adapters::SqliteProjection)
        raise "expected the native SqliteProjection path, got #{repository.adapter.class}"
      end

      native_rows = native_runtime.query("Banking.compliance_dashboard", account: "acct-1")

      in_process_runtime = build(adapter: "Memory")
      seed_disputed_card_payments
      in_process_rows = in_process_runtime.query("Banking.compliance_dashboard", account: "acct-1")

      canonical = ->(rows) { JSON.parse(JSON.generate(rows)) }
      expect(canonical.call(native_rows)).to eq(canonical.call(in_process_rows))
      # Confirms the `where`/`order_by`/`limit`/`offset` options were
      # actually exercised on both sides, not just an empty agreement.
      expect(native_rows.first[:card_payments].map { |p| p[:amount][:cents] }).to eq([300, 250, 200, 150, 100])
    end
  end

  # count/median are group_by's other reductions. Success/empty-set cases
  # dispatch the real DisputedPaymentCount/DisputedPaymentMedian read
  # models; the two refusal cases reopen the same "Banking" bluebook
  # chapter inline instead of adding fixture files, since a bluebook that
  # fails to build isn't a real corpus member to freeze.
  context "with count and median" do
    def build_with_bad_median(adapter: "Memory")
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
        Hecks.bluebook("Banking") do
          # A field that exists but is not numeric — refused at query
          # time, same as median's missing-field case below.
          read_model "BadMedianField" do
            reference_to Account
            include Account
            include CardPayment

            median :merchant
          end

          read_model "MissingMedianField" do
            reference_to Account
            include Account
            include CardPayment

            median :no_such_field
          end
        end
        Hecks.hecksagon("Banking") do
          attaches "Governance"
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
        Hecks.hecksagon("Governance") do
          Governance::RoleAssignment.persisted_by("Memory")
          Governance::RoleTransition.persisted_by("Memory")
        end
      end
      registry.verify!
      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    end

    def open_account(_runtime, customer:, account:)
      Banking::Customer.register!(reference: { value: customer }, name: { given: "A", family: "B" },
                                  email: { address: "#{customer}@example.com" })
      Banking::Account.open!(customer: customer, number: { value: account },
                             kind: { name: "current" }, daily_limit: { cents: 10_000 })
    end

    def dispute(account:, index:, cents:)
      pay = Banking::CardPayment.authorize!(account: account, authorisation: { value: "auth-#{account}-#{index}" },
                                            amount: { cents: cents }, merchant: { value: "Shop#{index}" })
      pay.capture!
      pay.dispute!(disputed_by: "c-#{account}")
    end

    it "counts a filtered set — how many match, not which ones" do
      runtime = build
      open_account(runtime, customer: "c-acct-count", account: "acct-count")
      [100, 200, 300].each_with_index { |cents, i| dispute(account: "acct-count", index: i, cents: cents) }
      # An undisputed payment too, so a count of 3 (not 4) proves `where`
      # actually filtered rather than the read model counting everything.
      Banking::CardPayment.authorize!(account: "acct-count", authorisation: { value: "auth-undisputed" },
                                      amount: { cents: 999 }, merchant: { value: "Undisputed" })

      rows = runtime.query("Banking.disputed_payment_count", account: "acct-count")
      expect(rows.first[:card_payments]).to eq(3)
    end

    it "counts zero for an account with nothing matching — an Integer, not nil" do
      runtime = build
      open_account(runtime, customer: "c-acct-empty-count", account: "acct-empty-count")

      rows = runtime.query("Banking.disputed_payment_count", account: "acct-empty-count")
      expect(rows.first[:card_payments]).to eq(0)
    end

    it "takes the middle value for an ODD number of rows" do
      runtime = build
      open_account(runtime, customer: "c-acct-median-odd", account: "acct-median-odd")
      [100, 500, 300].each_with_index { |cents, i| dispute(account: "acct-median-odd", index: i, cents: cents) }

      rows = runtime.query("Banking.disputed_payment_median", account: "acct-median-odd")
      expect(rows.first[:card_payments]).to eq(300)
    end

    # Averages the two middle values (300, 500), not the lower or upper
    # of the two, which a same-valued fixture couldn't distinguish.
    it "averages the two middle values for an EVEN number of rows" do
      runtime = build
      open_account(runtime, customer: "c-acct-median-even", account: "acct-median-even")
      [500, 100, 300, 700].each_with_index { |cents, i| dispute(account: "acct-median-even", index: i, cents: cents) }

      rows = runtime.query("Banking.disputed_payment_median", account: "acct-median-even")
      expect(rows.first[:card_payments]).to eq(400.0)
    end

    it "answers nil for the median of an empty set — not zero" do
      runtime = build
      open_account(runtime, customer: "c-acct-empty-median", account: "acct-empty-median")

      rows = runtime.query("Banking.disputed_payment_median", account: "acct-empty-median")
      expect(rows.first[:card_payments]).to be_nil
    end

    it "refuses a median field the aggregate does not declare, at query time" do
      runtime = build_with_bad_median
      open_account(runtime, customer: "c-acct-missing-field", account: "acct-missing-field")

      expect { runtime.query("Banking.missing_median_field", account: "acct-missing-field") }
        .to raise_error(ArgumentError, /no_such_field.*declares no such attribute/m)
    end

    it "refuses a median field that is not numeric, at query time" do
      runtime = build_with_bad_median
      open_account(runtime, customer: "c-acct-bad-field", account: "acct-bad-field")

      expect { runtime.query("Banking.bad_median_field", account: "acct-bad-field") }
        .to raise_error(ArgumentError, /merchant.*not numeric/m)
    end

    it "refuses count and median declared together" do
      expect do
        registry = Hecks::Runtime::Registry.new
        Hecks.with_registry(registry) do
          Kernel.load(InMemoryDomain::EXTRACTION_PORT)
          Kernel.load(InMemoryDomain::PRISM_ADAPTER)
          Hecks.bluebook("BothReductions") do
            vision "x"
            generic

            aggregate "Account" do
              identified_by :ref
              attribute :ref, Ref
              value_object "Ref" do
                attribute :value, String
              end
            end

            read_model "Both" do
              include Account

              count
              median :ref
            end
          end
        end
      end.to raise_error(Hecks::Bluebook::DSL::Malformed, /declares both count and median/)
    end

    it "refuses count declared together with group_by" do
      expect do
        registry = Hecks::Runtime::Registry.new
        Hecks.with_registry(registry) do
          Kernel.load(InMemoryDomain::EXTRACTION_PORT)
          Kernel.load(InMemoryDomain::PRISM_ADAPTER)
          Hecks.bluebook("CountAndGroup") do
            vision "x"
            generic

            aggregate "Account" do
              identified_by :ref
              attribute :ref, Ref
              value_object "Ref" do
                attribute :value, String
              end
            end

            read_model "Both" do
              include Account

              group_by :ref
              count
            end
          end
        end
      end.to raise_error(Hecks::Bluebook::DSL::Malformed, /declares count together with group_by/)
    end

    # The inline two-aggregate domain is the fixture for this refusal;
    # trimming it would lose the "more than one many-side head" shape.
    # rubocop:disable-next RSpec/ExampleLength
    it "refuses count declared with more than one many-side head" do
      expect do
        registry = Hecks::Runtime::Registry.new
        Hecks.with_registry(registry) do
          Kernel.load(InMemoryDomain::EXTRACTION_PORT)
          Kernel.load(InMemoryDomain::PRISM_ADAPTER)
          Hecks.bluebook("CrowdedCount") do
            vision "x"
            generic

            aggregate "Account" do
              identified_by :ref
              attribute :ref, Ref
              value_object "Ref" do
                attribute :value, String
              end
            end

            aggregate "Entry" do
              identified_by :ref
              attribute :ref, Ref
              value_object "Ref" do
                attribute :value, String
              end
            end

            read_model "Both" do
              include Account
              include Entry

              count
            end
          end
        end
      end.to raise_error(Hecks::Bluebook::DSL::Malformed, /declares count but includes 2 many-side/)
    end
  end

  # ADR 0078: sum/avg/min/max/percentile are sibling reductions to median, over the
  # same `where`-filtered CardPayment.amount field, now real corpus read models
  # (examples/banking/bluebook/customer_and_compliance_views.bluebook) — the plain
  # `build` helper above already loads them. any/all need a boolean field no aggregate
  # in this corpus declares yet, so they get their own small domain, below.
  context "with sum, avg, min, max, and percentile" do
    def open_new_account(customer:, account:)
      Banking::Customer.register!(reference: { value: customer }, name: { given: "A", family: "B" },
                                  email: { address: "#{customer}@example.com" })
      Banking::Account.open!(customer: customer, number: { value: account },
                             kind: { name: "current" }, daily_limit: { cents: 10_000 })
    end

    def dispute_payment(account:, index:, cents:)
      pay = Banking::CardPayment.authorize!(account: account, authorisation: { value: "auth-#{account}-#{index}" },
                                            amount: { cents: cents }, merchant: { value: "Shop#{index}" })
      pay.capture!
      pay.dispute!(disputed_by: "c-#{account}")
    end

    # Same four disputed amounts (and the same even-count shape) as "averages the
    # two middle values", above, so this fixture's own median (400.0) is already
    # known good — sum/avg/min/max/p95 are hand-computed against the same set.
    it "sums, averages, and finds the extremes of a filtered set" do
      runtime = build
      open_new_account(customer: "c-acct-sum", account: "acct-sum")
      [500, 100, 300, 700].each_with_index { |cents, i| dispute_payment(account: "acct-sum", index: i, cents: cents) }

      expect(runtime.query("Banking.disputed_payment_total", account: "acct-sum").first[:card_payments]).to eq(1600)
      expect(runtime.query("Banking.disputed_payment_average", account: "acct-sum").first[:card_payments]).to eq(400.0)
      expect(runtime.query("Banking.disputed_payment_smallest", account: "acct-sum").first[:card_payments]).to eq(100)
      expect(runtime.query("Banking.disputed_payment_largest", account: "acct-sum").first[:card_payments]).to eq(700)
      # Sorted: [100, 300, 500, 700]; pos = 0.95 * 3 = 2.85 -> 500 + 0.85 * (700 - 500)
      expect(runtime.query("Banking.disputed_payment_p95", account: "acct-sum").first[:card_payments]).to eq(670.0)
    end

    it "sums to zero and averages/extremes to nil for an empty set" do
      runtime = build
      open_new_account(customer: "c-acct-sum-empty", account: "acct-sum-empty")

      expect(runtime.query("Banking.disputed_payment_total", account: "acct-sum-empty").first[:card_payments]).to eq(0)
      expect(runtime.query("Banking.disputed_payment_average", account: "acct-sum-empty").first[:card_payments]).to be_nil
      expect(runtime.query("Banking.disputed_payment_smallest", account: "acct-sum-empty").first[:card_payments]).to be_nil
      expect(runtime.query("Banking.disputed_payment_largest", account: "acct-sum-empty").first[:card_payments]).to be_nil
    end

    # The full Banking boot is the fixture for this refusal; trimming it would lose
    # the real-domain shape (a genuine non-numeric field on a real aggregate).
    # rubocop:disable-next RSpec/ExampleLength
    it "refuses a sum field that is not an Integer, at query time" do
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
        Hecks.bluebook("Banking") do
          read_model "BadSumField" do
            reference_to Account
            include Account
            include CardPayment

            sum :merchant
          end
        end
        Hecks.hecksagon("Banking") do
          attaches "Governance"
          Banking::Customer.persisted_by("Memory")
          Banking::Account.persisted_by("Memory")
          Banking::ATMCard.persisted_by("Memory")
          Banking::Transfer.persisted_by("Memory")
          Banking::CardPayment.persisted_by("Memory")
          Banking::ExternalTransfer.persisted_by("Memory")
          Banking::ScheduledPayment.persisted_by("Memory")
          Banking::SafeDepositBox.persisted_by("Memory")
          Banking::OnboardingCase.persisted_by("Memory")
        end
        Hecks.hecksagon("Governance") do
          Governance::RoleAssignment.persisted_by("Memory")
          Governance::RoleTransition.persisted_by("Memory")
        end
      end
      registry.verify!
      runtime = Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
      open_new_account(customer: "c-acct-bad-sum", account: "acct-bad-sum")

      expect { runtime.query("Banking.bad_sum_field", account: "acct-bad-sum") }
        .to raise_error(ArgumentError, /merchant.*not numeric/m)
    end

    it "refuses more than one reduction declared together" do
      expect do
        registry = Hecks::Runtime::Registry.new
        Hecks.with_registry(registry) do
          Kernel.load(InMemoryDomain::EXTRACTION_PORT)
          Kernel.load(InMemoryDomain::PRISM_ADAPTER)
          Hecks.bluebook("SumAndMax") do
            vision "x"
            generic

            aggregate "Account" do
              identified_by :ref
              attribute :ref, Ref
              value_object "Ref" do
                attribute :value, String
              end
            end

            read_model "Both" do
              include Account

              sum :ref
              max :ref
            end
          end
        end
      end.to raise_error(Hecks::Bluebook::DSL::Malformed, /declares both sum and max/)
    end
  end

  context "with any and all" do
    # A whole fresh domain (aggregate, command, two read models) is the fixture for
    # any/all — no aggregate in the real Banking corpus has a bare boolean field yet.
    # rubocop:disable-next Metrics/AbcSize
    # rubocop:disable-next Metrics/MethodLength
    def build_with_boolean_reductions(adapter: "Memory")
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Hecks.bluebook("Widgets") do
          vision "a boolean-reduction fixture"
          generic

          aggregate "Shelf" do
            identified_by :ref
            attribute :ref, Ref
            value_object "Ref" do
              attribute :value, String
            end

            command "Open" do
              sets :ref
              emits "Opened"
            end
          end

          aggregate "Widget" do
            reference_to Shelf
            identified_by :ref
            attribute :ref, Ref
            attribute :flagged, Flag
            value_object "Ref" do
              attribute :value, String
            end
            value_object "Flag" do
              attribute :value, TrueClass
            end

            command "Place" do
              sets :shelf
              sets :ref
              sets :flagged
              emits "Placed"
            end
          end

          read_model "ShelfHasFlagged" do
            reference_to Shelf
            include Shelf
            include Widget

            any :flagged
          end

          read_model "ShelfAllFlagged" do
            reference_to Shelf
            include Shelf
            include Widget

            all :flagged
          end
        end
        Hecks.hecksagon("Widgets") do
          Widgets::Shelf.persisted_by(adapter)
          Widgets::Widget.persisted_by(adapter)
        end
      end
      registry.verify!
      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    end

    it "answers any/all over a boolean field, and the empty-set vacuous-truth cases" do
      runtime = build_with_boolean_reductions
      Widgets::Shelf.open!(ref: { value: "s-mixed" })
      Widgets::Widget.place!(shelf: "s-mixed", ref: { value: "w1" }, flagged: { value: true })
      Widgets::Widget.place!(shelf: "s-mixed", ref: { value: "w2" }, flagged: { value: false })

      expect(runtime.query("Widgets.shelf_has_flagged", shelf: "s-mixed").first[:widgets]).to be true
      expect(runtime.query("Widgets.shelf_all_flagged", shelf: "s-mixed").first[:widgets]).to be false

      Widgets::Shelf.open!(ref: { value: "s-empty" })
      # `any` of nothing is false; `all` of nothing is true (the ordinary
      # `or`-identity/`and`-identity vacuous-truth reading, ADR 0078).
      expect(runtime.query("Widgets.shelf_has_flagged", shelf: "s-empty").first[:widgets]).to be false
      expect(runtime.query("Widgets.shelf_all_flagged", shelf: "s-empty").first[:widgets]).to be true
    end
  end
end

# A rootless read model (no `reference_to`) nests a many-side head's own
# table by field values via `group_by`, unwrapping single-attribute value
# objects to bare scalars along the way. Every report without group_by
# stays unaffected.
RSpec.describe "a rootless read model's own group_by" do
  def build(adapter: "Memory")
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
      Hecks.hecksagon("Banking") do
        attaches "Governance"
        Banking::Customer.persisted_by(adapter)
        Banking::Account.persisted_by(adapter)
      end
      Hecks.hecksagon("Governance") do
        Governance::RoleAssignment.persisted_by("Memory")
        Governance::RoleTransition.persisted_by("Memory")
      end
      yield if block_given?
    end
    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def open_accounts(_runtime)
    Banking::Customer.register!(reference: { value: "c1" }, name: { given: "A", family: "B" },
                                email: { address: "a@example.com" })
    Banking::Account.open!(customer: "c1", number: { value: "a1" }, kind: { name: "current" }, daily_limit: { cents: 0 })
    Banking::Account.open!(customer: "c1", number: { value: "a2" }, kind: { name: "savings" }, daily_limit: { cents: 0 })
    Banking::Account.open!(customer: "c1", number: { value: "a3" }, kind: { name: "current" }, daily_limit: { cents: 0 })
  end

  # AccountsByKind is a real corpus report (banking.bluebook), proving
  # this feature against an already-model-checked domain.
  it "reads a whole aggregate's own table in bulk, no id argument, nested by one field" do
    runtime = build
    open_accounts(runtime)

    rows = runtime.query("Banking.accounts_by_kind")
    grouped = rows.first[:accounts]

    expect(grouped.keys.sort).to eq(%w[current savings])
    expect(grouped["current"].keys.sort).to eq(%w[a1 a3])
    expect(grouped["savings"].keys).to eq(["a2"])
  end

  it "unwraps single-attribute value objects on the grouped head's own rows" do
    runtime = build
    open_accounts(runtime)

    row = runtime.query("Banking.accounts_by_kind").first[:accounts]["current"]["a1"]

    # `number`/`kind` are group_by fields, already spent as keys, so they
    # don't survive into the leaf. `daily_limit` isn't part of group_by,
    # so it's the field left to check: a bare Integer, not `{cents: 0}`.
    expect(row[:daily_limit]).to eq(0)
  end

  # Proves multi-field group_by nesting end-to-end. Named "Gadget", not
  # "Widget" — see the comment below on the constant collision that avoids.
  # rubocop:disable-next RSpec/ExampleLength
  it "nests by several fields, one level per field, in declared order" do
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Hecks.bluebook("Nested") do
        vision "x"
        generic

        # "Gadget", not "Widget" — other spec files declare their own
        # top-level "Widget" domain; nesting a same-named constant under
        # "Nested" here caused a real, order-dependent lookup collision
        # under `config.order = :random`.
        aggregate "Gadget" do
          identified_by :ref
          attribute :ref,   Ref
          attribute :group, Ref
          value_object "Ref" do
            attribute :value, String
          end
          command "Declare" do
            attribute :ref,   Ref
            attribute :group, Ref
            sets :ref
            sets :group
          end
        end

        read_model "Grouped" do
          include Gadget

          group_by :group, :ref
        end
      end
      Hecks.hecksagon("Nested") { Nested::Gadget.persisted_by("Memory") }
    end
    registry.verify!
    runtime = Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))

    Nested::Gadget.declare!(ref: { value: "w1" }, group: { value: "g1" })
    Nested::Gadget.declare!(ref: { value: "w2" }, group: { value: "g1" })
    Nested::Gadget.declare!(ref: { value: "w3" }, group: { value: "g2" })

    grouped = runtime.query("Nested.grouped").first[:gadgets]

    expect(grouped).to eq(
      "g1" => { "w1" => { id: "w1" }, "w2" => { id: "w2" } },
      "g2" => { "w3" => { id: "w3" } }
    )
  end

  # ADR 0061 D1: a group_by leaf holds one row. Two rows sharing a full
  # key path refuse at dispatch; a key path covering the grouped
  # aggregate's own identity is accepted from the declaration.
  describe "a key path two rows share" do
    def boot_colliding
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Hecks.bluebook("Collide") do
          vision "x"
          generic

          aggregate "Sprocket" do
            identified_by :ref
            attribute :ref,   Ref
            attribute :group, Ref
            value_object "Ref" do
              attribute :value, String
            end
            command "Declare" do
              attribute :ref,   Ref
              attribute :group, Ref
              sets :ref
              sets :group
            end
          end

          read_model "ByGroup" do
            include Sprocket

            group_by :group
          end

          read_model "ByGroupAndRef" do
            include Sprocket

            group_by :group, :ref
          end
        end
        Hecks.hecksagon("Collide") { Collide::Sprocket.persisted_by("Memory") }
      end
      registry.verify!
      runtime = Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
      Collide::Sprocket.declare!(ref: { value: "w1" }, group: { value: "g1" })
      Collide::Sprocket.declare!(ref: { value: "w2" }, group: { value: "g1" })
      Collide::Sprocket.declare!(ref: { value: "w3" }, group: { value: "g2" })
      runtime
    end

    it "refuses, naming the read model, the key path and the colliding ids" do
      runtime = boot_colliding

      expect { runtime.query("Collide.by_group") }.to raise_error(
        Hecks::Runtime::InvariantViolation,
        'ByGroup groups by group, but rows "w1", "w2" share group = g1 — a group_by leaf holds one row; ' \
        "add a field that tells them apart"
      )
    end

    it "answers when the key path covers the grouped aggregate's identity" do
      grouped = boot_colliding.query("Collide.by_group_and_ref").first[:sprockets]

      expect(grouped).to eq("g1" => { "w1" => { id: "w1" }, "w2" => { id: "w2" } }, "g2" => { "w3" => { id: "w3" } })
    end

    it "accepts an identity-covering key path from the declaration alone" do
      bluebook = boot_colliding.registry.bluebook("Collide")
      sprocket = bluebook.aggregate("Sprocket")

      expect(bluebook.read_model("ByGroupAndRef").groups_by_identity?(sprocket)).to be(true)
      expect(bluebook.read_model("ByGroup").groups_by_identity?(sprocket)).to be(false)
    end
  end

  it "refuses group_by naming a field the aggregate doesn't declare" do
    runtime = build
    open_accounts(runtime)

    registry = runtime.registry
    bluebook = registry.bluebook("Banking")
    model = bluebook.read_model("AccountsByKind")
    bad = Hecks::Bluebook::ReadModel.new(
      name: model.name, reference_name: nil, reference_target: nil,
      aggregate_heads: model.aggregate_heads, group_by: [{ field: :no_such_field }]
    )

    expect do
      Hecks::Runtime::ReadModelInterpreter.new(registry).send(:project, "Banking", bad, {})
    end.to raise_error(ArgumentError, /no_such_field.*declares no such attribute/m)
  end

  it "refuses group_by declared with zero many-side heads" do
    expect do
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Hecks.bluebook("Rootful") do
          vision "x"
          generic

          aggregate "Account" do
            identified_by :ref
            attribute :ref, Ref
            value_object "Ref" do
              attribute :value, String
            end
          end

          read_model "Solo" do
            reference_to Account
            include Account

            group_by :ref
          end
        end
      end
    end.to raise_error(Hecks::Bluebook::DSL::Malformed, /declares group_by but includes 0 many-side/)
  end

  # The inline two-aggregate domain is the fixture for this refusal;
  # trimming it would lose the "more than one many-side head" shape.
  # rubocop:disable-next RSpec/ExampleLength
  it "refuses group_by declared with more than one many-side head" do
    expect do
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Hecks.bluebook("Crowded2") do
          vision "x"
          generic

          aggregate "Account" do
            identified_by :ref
            attribute :ref, Ref
            value_object "Ref" do
              attribute :value, String
            end
          end

          aggregate "Entry" do
            identified_by :ref
            attribute :ref, Ref
            value_object "Ref" do
              attribute :value, String
            end
          end

          read_model "Both" do
            include Account
            include Entry

            group_by :ref
          end
        end
      end
    end.to raise_error(Hecks::Bluebook::DSL::Malformed, /declares group_by but includes 2 many-side/)
  end

  # Proves group_by applies through Sqlite's own boot, reusing
  # open_accounts already set up above.
  # rubocop:disable-next RSpec/ExampleLength
  it "applies group_by through Sqlite's own boot too, by skipping the native escape hatch" do
    Dir.mktmpdir do |dir|
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/sqlite.adapter"))
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
        Hecks.hecksagon("Banking") do
          attaches "Governance"
          Banking::Customer.persisted_by("SqlitePersistence")
          Banking::Account.persisted_by("SqlitePersistence")
        end
        Hecks.hecksagon("Governance") do
          Governance::RoleAssignment.persisted_by("Memory")
          Governance::RoleTransition.persisted_by("Memory")
        end
        Hecks.world("Banking") do
          persisted_by("SqlitePersistence") { database File.join(dir, "banking.db") }
        end
      end
      registry.verify!
      runtime = Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))

      open_accounts(runtime)

      grouped = runtime.query("Banking.accounts_by_kind").first[:accounts]
      expect(grouped.keys.sort).to eq(%w[current savings])
      # "a1" is number's own unwrapped key (see the in-memory unwrap
      # test); daily_limit is the field still present to check here.
      expect(grouped["current"]["a1"][:daily_limit]).to eq(0)
    end
  end
end
