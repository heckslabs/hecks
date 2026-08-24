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
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
      Hecks.hecksagon("Banking") do
        uses_framework "Governance"
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

  # ELEVEN disputed amounts (S13, ADR 0025 — coverage standard,
  # ComplianceDashboard gained a real `offset 5` alongside its own
  # `limit 5`) — enough for TWO full pages (the top 5, then the next
  # 5) plus one beyond both, so the cap trims something on EACH page,
  # not just the first. A twelfth, undisputed payment proves
  # `where(status: "disputed")` actually filters, not just "everything
  # CardPayment holds".
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

    # `offset 5` (S13, ADR 0025) skips the top 5 — the SECOND page, not
    # the first, still ordered and still capped at 5.
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

  it "leaves a read model with no declared options exactly as before" do
    runtime = build
    seed_disputed_card_payments

    rows = runtime.query("Banking.customer_portfolio", customer: "c1")
    expect(rows.first[:card_payments].map { |p| p[:amount][:cents] })
      .to contain_exactly(100, 600, 300, 500, 200, 400, 150, 550, 250, 450, 50, 999)
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
      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    end

    runtime = build_reversed.call
    Reordered::Item.add!(name: { value: "headlamp" })
    Reordered::Promotion.promote!(ref: { value: "p1" }, item: "headlamp")

    rows = runtime.query("Reordered.search", item: "headlamp")

    expect(rows.first[:item][:id]).to eq("headlamp")
    expect(rows.first[:promotions].map { |p| p[:id] }).to eq(["p1"])
  end

  it "applies the same options through Sqlite's native projected-table path" do
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
          uses_framework "Governance"
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

      rows = runtime.query("Banking.compliance_dashboard", account: "acct-1")
      # `offset 5` — see the in-memory version of this same assertion above.
      expect(rows.first[:card_payments].map { |p| p[:amount][:cents] }).to eq([300, 250, 200, 150, 100])
    end
  end

  # `count`/`median` — the other two reductions `group_by` has siblings
  # in (read_model_builder.rb's own `seal_aggregation`). The success/
  # empty-set cases below dispatch banking.bluebook's OWN real
  # `DisputedPaymentCount`/`DisputedPaymentMedian` read models (added
  # alongside this task, the real corpus member `spec/judge_coverage_
  # spec.rb` needs to ever OFFER `ReadModel.Count`/`ReadModel.Median` to
  # the meta-domain at all — a verb the judge never offers is a verb
  # every rule about it is decoration for, that spec's own header) — the
  # `build` helper above already loads and persists the whole chapter,
  # so no reopening is needed for them. The two REFUSAL cases (a median
  # field that doesn't exist, or exists but isn't numeric) are declared
  # on tiny read models reopening the same already-loaded "Banking"
  # chapter instead (`Hecks.bluebook "Banking" do ... end` a second time
  # — `BluebookBuilder.build` keeps one builder open per chapter name
  # across calls) rather than in the file itself, because a bluebook
  # that fails to build is not a real corpus member to freeze.
  context "count and median" do
    def build_with_bad_median(adapter: "Memory")
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
        Hecks.bluebook("Banking") do
          # A field that exists but is not numeric (a single-String
          # value object, `MerchantName{value}`) — refused at QUERY
          # time, not at build time, the same as `median`'s missing-
          # field case below and `group_by_target`'s own field checks.
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
          uses_framework "Governance"
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

    def open_account(runtime, customer:, account:)
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
      # An UNDISPUTED payment too, so a count of 3 (not 4) proves `where`
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

    # THE DEFINITIONAL CHOICE THIS SESSION MADE, PROVEN: the AVERAGE of
    # the two middle values (300 and 500, sorted from [500, 100, 300,
    # 700] -> [100, 300, 500, 700]), not the lower of the two (which
    # would silently read 300 here too) or the upper (500) — a real
    # ambiguity a same-valued fixture could not have caught.
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
      end.to raise_error(Hecks::Bluebook::DSL::Malformed, /declares count\/median together with group_by/)
    end

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
      end.to raise_error(Hecks::Bluebook::DSL::Malformed, /declares count\/median but includes 2 many-side/)
    end
  end
end

# A read model used to always need exactly one root record — `reference_to`
# was required, and dispatch always took exactly one id argument. `group_by`
# is what a report can't do without either: nesting an aggregate's OWN whole
# table by its own field values has no root to anchor to. So `reference_to`
# became optional (a ROOTLESS read model, bulk, no id at dispatch), and
# `group_by` nests one eligible head's rows into a Hash — unwrapping every
# single-attribute value object on that head's own rows to its bare scalar
# along the way, since grouping needs a real scalar to key by regardless.
# Every OTHER report (no group_by declared) is provably unaffected — see
# "leaves a read model with no declared options exactly as before" above,
# unchanged by this feature.
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
        uses_framework "Governance"
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

  def open_accounts(runtime)
    Banking::Customer.register!(reference: { value: "c1" }, name: { given: "A", family: "B" },
                                email: { address: "a@example.com" })
    Banking::Account.open!(customer: "c1", number: { value: "a1" }, kind: { name: "current" }, daily_limit: { cents: 0 })
    Banking::Account.open!(customer: "c1", number: { value: "a2" }, kind: { name: "savings" }, daily_limit: { cents: 0 })
    Banking::Account.open!(customer: "c1", number: { value: "a3" }, kind: { name: "current" }, daily_limit: { cents: 0 })
  end

  # THE REAL CORPUS MEMBER, not a synthetic fixture — `AccountsByKind`,
  # banking.bluebook's own third report, exists specifically so this
  # feature is proven against a real, already-model-checked domain, the
  # same discipline `judge_coverage_spec`/`plurality_coverage_spec`
  # already hold every other declared construct to.
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

    # `number`/`kind` are BOTH group_by fields here (AccountsByKind
    # groups by `:kind, :number`), so neither survives into the leaf —
    # already spent, as the keys that reached it (the "current" => "a1"
    # nesting IS `number`'s own unwrapped value; a still-wrapped
    # `{value: "a1"}` couldn't have been a Hash key at all). `daily_
    # limit` (DailyLimit{cents}) is a DIFFERENT single-attribute VO,
    # not part of group_by, so it's the one still actually present to
    # check: bare Integer, not `{cents: 0}`, the way every OTHER
    # report's own output still wraps it (see "leaves a read model
    # with no declared options exactly as before").
    expect(row[:daily_limit]).to eq(0)
  end

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

        # "Gadget", not "Widget" — half a dozen OTHER spec files declare
        # their own bare, top-level "Widget" domain (dsl_spec.rb,
        # mutation_spec.rb, smoke_test_spec.rb, ...), and this is the
        # only one that nests its "Widget" under an outer "Nested"
        # domain. A real, measured collision: whichever ran first left
        # `Nested::Widget` sitting in the global constant table, and
        # under `config.order = :random` the NEXT example to declare
        # its OWN bare `Widget` domain sometimes found Ruby's constant
        # lookup climbing into `Nested::Widget` before ever reaching
        # `::Widget` — `uninitialized constant Nested::Widget::Item`,
        # order-dependent, reproduced directly (not guessed at).
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
          uses_framework "Governance"
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
      # "current" => "a1" IS number's own unwrapped value (see the
      # in-memory unwrap test's own comment) — `daily_limit` is the
      # still-present single-attribute VO to check here.
      expect(grouped["current"]["a1"][:daily_limit]).to eq(0)
    end
  end
end
