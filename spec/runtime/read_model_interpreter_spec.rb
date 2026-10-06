require "spec_helper"
require "tmpdir"
require "json"
require_relative "../support/read_model_spec_helpers"

# where/order_by/limit/offset apply to a read model's one many-side
# collection, honored identically by the in-memory (Memory, Postgres),
# and Sqlite projected-table interpreter paths.
RSpec.describe "a read model's query options" do
  include ReadModelSpecHelpers

  # Eleven disputed amounts: two full pages of 5 plus one left over, so the
  # cap trims something on each page, not just the first. A twelfth,
  # undisputed payment proves `where(status: "disputed")` actually filters.
  DISPUTED_AMOUNTS = [100, 600, 300, 500, 200, 400, 150, 550, 250, 450, 50].freeze

  MALFORMED = Hecks::Bluebook::DSL::Malformed

  # Adds a second read model to the already-loaded Banking domain from Ruby,
  # not a file under `examples/banking/bluebook/` — rust/parser doesn't yet
  # recognize `on:` and would misparse it.
  MULTI_TARGET_READ_MODEL = proc do
    read_model "MultiTarget" do
      reference_to Account
      include Account
      include CardPayment
      include ATMCard

      where(status: "disputed", on: CardPayment)
    end
  end

  BAD_MEDIAN_READ_MODELS = proc do
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

  BAD_SUM_READ_MODEL = proc do
    read_model "BadSumField" do
      reference_to Account
      include Account
      include CardPayment

      sum :merchant
    end
  end

  SOLITARY_DOMAIN = proc do
    vision "x"
    generic
    instance_exec(&READ_MODEL_ACCOUNT_AGGREGATE)

    read_model "Solo" do
      reference_to Account
      include Account

      where(ref: "a1")
    end
  end

  CROWDED_DOMAIN = proc do
    vision "x"
    generic
    instance_exec(&READ_MODEL_ACCOUNT_AGGREGATE)
    instance_exec(&READ_MODEL_LINKED_ENTRY_AGGREGATE)
    instance_exec(&READ_MODEL_LINKED_NOTE_AGGREGATE)

    read_model "Both" do
      reference_to Account
      include Account
      include Entry
      include Note

      limit 1
    end
  end

  # `on:` naming an aggregate that isn't a many-side head is a real typo
  # shape, distinct from omitting `on:` entirely. `Account` is the root, a
  # single row, so it can never be a legal target regardless of head count.
  MISTARGETED_DOMAIN = proc do
    vision "x"
    generic
    instance_exec(&READ_MODEL_ACCOUNT_AGGREGATE)
    instance_exec(&READ_MODEL_LINKED_ENTRY_AGGREGATE)
    instance_exec(&READ_MODEL_LINKED_NOTE_AGGREGATE)

    read_model "Both" do
      reference_to Account
      include Account
      include Entry
      include Note

      where(ref: "a1", on: Account)
    end
  end

  ITEM_AGGREGATE = proc do
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
  end

  PROMOTION_AGGREGATE = proc do
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
  end

  # Pins a real bug: the join matched a many-side head against whatever was
  # already accumulated, which is empty when that head is declared before
  # the root — a silent, wrong empty result, not an error. Every real
  # corpus read model happens to declare its root first, so only a
  # deliberately reordered domain catches this.
  REORDERED_DOMAIN = proc do
    vision "x"
    generic
    instance_exec(&ITEM_AGGREGATE)
    instance_exec(&PROMOTION_AGGREGATE)

    # The many side declared first — the ordering that broke.
    read_model "Search" do
      reference_to Item
      include Promotion
      include Item
    end
  end

  # Root-first alone doesn't reach a chain of non-root heads: Coupon
  # (which needs Promotion resolved) declared before Promotion, with the
  # root last, is the worst order for the old code and pins that a
  # dependency chain more than one level deep resolves correctly
  # regardless of declaration order.
  CHAINED_DOMAIN = proc do
    vision "x"
    generic
    instance_exec(&ITEM_AGGREGATE)
    instance_exec(&PROMOTION_AGGREGATE)

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

  # `include` also accepts a nested entity (declared with `entity` inside
  # an aggregate), not just a top-level aggregate. `bluebook.aggregate`
  # only searches top-level aggregates, so an entity head resolves to
  # nil; this pins that the ordering pass tolerates that (an empty result
  # for that head, not a crash) while a real dependency chain around it
  # still resolves correctly.
  ENTITY_HEADED_DOMAIN = proc do
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

    instance_exec(&PROMOTION_AGGREGATE)

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

  def build(adapter: "Memory") = boot_banking_bundle(adapter: adapter)

  def build_with_targeted_read_model = boot_banking_bundle(extra: MULTI_TARGET_READ_MODEL)

  def dispute_seeded(index, cents)
    pay = Banking::CardPayment.authorize!(account: "acct-1", authorisation: { value: "auth-#{index}" },
                                          amount: { cents: cents }, merchant: { value: "Shop#{index}" })
    pay.capture!
    pay.dispute!(disputed_by: "c1")
  end

  def seed_disputed_card_payments
    Banking::Customer.register!(reference: { value: "c1" }, name: { given: "A", family: "B" },
                                email: { address: "a@example.com" })
    Banking::Account.open!(customer: "c1", number: { value: "acct-1" },
                           kind: { name: "current" }, daily_limit: { cents: 10_000 })
    DISPUTED_AMOUNTS.each_with_index { |cents, index| dispute_seeded(index, cents) }
    Banking::CardPayment.authorize!(account: "acct-1", authorisation: { value: "auth-undisputed" },
                                    amount: { cents: 999 }, merchant: { value: "Undisputed Shop" })
  end

  def issue_cards(*serials)
    serials.each { |serial| Banking::ATMCard.issue!(account: "acct-1", serial: { value: serial }, daily_fee: { amount: 0.0 }) }
  end

  def seeded_targeted_runtime
    runtime = build_with_targeted_read_model
    seed_disputed_card_payments
    issue_cards("card-1", "card-2")
    runtime
  end

  def register_customer(customer, account)
    Banking::Customer.register!(reference: { value: customer }, name: { given: "A", family: "B" },
                                email: { address: "#{customer}@example.com" })
    Banking::Account.open!(customer: customer, number: { value: account },
                           kind: { name: "current" }, daily_limit: { cents: 10_000 })
  end

  def card_payment_cents(rows) = rows.first[:card_payments].map { |p| p[:amount][:cents] }

  # Boots a three-aggregate Item/Promotion domain and seeds one promoted item.
  def seeded_search_runtime(name, body, aggregates)
    runtime = boot_memory_domain(name, body, aggregates: aggregates)
    domain = Object.const_get(name)
    domain::Item.add!(name: { value: "headlamp" })
    domain::Promotion.promote!(ref: { value: "p1" }, item: "headlamp")
    runtime
  end

  it "filters, orders, and caps the one many-side collection" do
    runtime = build
    seed_disputed_card_payments

    # `offset 5` skips the first page — still ordered and capped at 5.
    expect(card_payment_cents(runtime.query("Banking.compliance_dashboard", account: "acct-1")))
      .to eq([300, 250, 200, 150, 100])
  end

  it "refuses at build with zero many-side heads" do
    expect(&domain_build("Solitary", SOLITARY_DOMAIN))
      .to raise_error(MALFORMED, /includes 0 many-side aggregates, not exactly one/)
  end

  it "refuses at build with more than one many-side head" do
    expect(&domain_build("Crowded", CROWDED_DOMAIN))
      .to raise_error(MALFORMED, /includes 2 many-side aggregates, not exactly one/)
  end

  it "refuses `on:` that doesn't name one of its own many-side aggregates" do
    expect(&domain_build("Mistargeted", MISTARGETED_DOMAIN))
      .to raise_error(MALFORMED, /doesn't name one of its own many-side included aggregates/)
  end

  # `on:` names which many-side head query options target when a read
  # model includes more than one; `CardPayment` is filtered while `ATMCard`,
  # with no `on:` of its own, comes back whole.
  #
  # Declared here in Ruby, not under `examples/banking/bluebook/`, because
  # `rust/parser` doesn't yet recognize `on:` and would misparse it as an
  # ordinary where-field.
  it "filters one many-side collection with `on:`, leaving another untouched", :aggregate_failures do
    runtime = seeded_targeted_runtime
    rows = runtime.query("Banking.multi_target", account: "acct-1")
    expect(card_payment_cents(rows).sort).to eq(DISPUTED_AMOUNTS.sort)
    expect(rows.first[:atm_cards].map { |c| c[:serial][:value] }.sort).to eq(%w[card-1 card-2])
  end

  it "leaves a read model with no declared options exactly as before" do
    runtime = build
    seed_disputed_card_payments

    expect(card_payment_cents(runtime.query("Banking.customer_portfolio", customer: "c1")))
      .to contain_exactly(100, 600, 300, 500, 200, 400, 150, 550, 250, 450, 50, 999)
  end

  it "joins the many side correctly regardless of which order include declares it and the root in",
     :aggregate_failures do
    rows = seeded_search_runtime("Reordered", REORDERED_DOMAIN, ["Item", "Promotion"])
           .query("Reordered.search", item: "headlamp")

    expect(rows.first[:item][:id]).to eq("headlamp")
    expect(rows.first[:promotions].map { |p| p[:id] }).to eq(["p1"])
  end

  it "joins a CHAIN of non-root heads correctly regardless of declaration order, not just one level deep",
     :aggregate_failures do
    runtime = seeded_search_runtime("Chained", CHAINED_DOMAIN, ["Item", "Promotion", "Coupon"])
    Chained::Coupon.issue!(ref: { value: "c1" }, promotion: "p1")

    rows = runtime.query("Chained.search", item: "headlamp")

    expect([rows.first[:item][:id], rows.first[:promotions].map { |p| p[:id] }]).to eq(["headlamp", ["p1"]])
    expect(rows.first[:coupons].map { |c| c[:id] }).to eq(["c1"])
  end

  it "tolerates an included head that is a nested entity, not a top-level aggregate, without crashing",
     :aggregate_failures do
    rows = seeded_search_runtime("EntityHeaded", ENTITY_HEADED_DOMAIN, ["Item", "Promotion"])
           .query("EntityHeaded.search", item: "headlamp")

    expect([rows.first[:item][:id], rows.first[:promotions].map { |p| p[:id] }]).to eq(["headlamp", ["p1"]])
    # An entity head has no repository of its own to read from, so empty,
    # not a crash, is the correct current answer.
    expect(rows.first[:notes]).to eq([])
  end

  describe "against a real Sqlite store" do
    around do |example|
      Dir.mktmpdir do |tmp|
        @dir = tmp
        example.run
      end
    end

    attr_reader :dir

    # Confirms by construction that no stray `projected_by` silently moved the in-process
    # path onto the native one.
    def expect_plain_sqlite(runtime)
      adapter = runtime.registry.read_repository("Banking", runtime.registry.bluebook("Banking").aggregate("Account")).adapter
      expect(adapter).to be_a(Hecks::Adapters::Sqlite).and(satisfy { |a| !a.is_a?(Hecks::Adapters::SqliteProjection) })
    end

    def expect_native_projection(runtime)
      adapter = runtime.registry.read_repository("Banking", runtime.registry.bluebook("Banking").aggregate("Account")).adapter
      expect(adapter).to be_a(Hecks::Adapters::SqliteProjection)
    end

    def catch_up_projections(registry)
      ["Account", "CardPayment"].each do |name|
        Hecks::Ports::Projection.worker(registry, "Banking", registry.bluebook("Banking").aggregate(name))&.catch_up!
      end
    end

    def native_dashboard_rows
      runtime = boot_sqlite_banking(dir, persisted: ["Customer", "Account", "CardPayment"], projected: ["Account", "CardPayment"])
      seed_disputed_card_payments
      catch_up_projections(runtime.registry)
      expect_native_projection(runtime)
      runtime.query("Banking.compliance_dashboard", account: "acct-1")
    end

    def in_process_dashboard_rows
      runtime = build(adapter: "Memory")
      seed_disputed_card_payments
      runtime.query("Banking.compliance_dashboard", account: "acct-1")
    end

    def canonical(rows) = JSON.parse(JSON.generate(rows))

    # Proves the same options apply against a real SQLite-backed store. No
    # `projected_by` is bound, so this exercises the in-process
    # `ReadModelInterpreter` path (`SqlitePersistence`), not
    # `SqliteProjection`'s native path — see the next example for that.
    it "applies the same options through a real Sqlite-backed authoritative store (in-process path)" do
      runtime = boot_sqlite_banking(dir, persisted: ["Customer", "Account", "CardPayment"])
      seed_disputed_card_payments
      expect_plain_sqlite(runtime)

      # `offset 5` — see the in-memory version of this same assertion above.
      expect(card_payment_cents(runtime.query("Banking.compliance_dashboard", account: "acct-1")))
        .to eq([300, 250, 200, 150, 100])
    end

    # The real native-path proof: exercises `SqliteProjection#query_read_model`
    # against a read model with real where/order_by/limit/offset, and
    # compares the native result against an independently-booted in-process
    # run fed the same seed, rather than a second hand-typed literal that
    # could drift the same wrong way.
    it "agrees with the in-process path through Sqlite's real native projected-table path", :aggregate_failures do
      native_rows = native_dashboard_rows
      in_process_rows = in_process_dashboard_rows

      expect(canonical(native_rows)).to eq(canonical(in_process_rows))
      # Confirms the `where`/`order_by`/`limit`/`offset` options were
      # actually exercised on both sides, not just an empty agreement.
      expect(card_payment_cents(native_rows)).to eq([300, 250, 200, 150, 100])
    end
  end

  # count/median are group_by's other reductions. Success/empty-set cases
  # dispatch the real DisputedPaymentCount/DisputedPaymentMedian read
  # models; the two refusal cases reopen the same "Banking" bluebook
  # chapter inline instead of adding fixture files, since a bluebook that
  # fails to build isn't a real corpus member to freeze.
  context "with count and median" do
    BOTH_REDUCTIONS_DOMAIN = proc do
      vision "x"
      generic
      instance_exec(&READ_MODEL_ACCOUNT_AGGREGATE)

      read_model "Both" do
        include Account

        count
        median :ref
      end
    end

    COUNT_AND_GROUP_DOMAIN = proc do
      vision "x"
      generic
      instance_exec(&READ_MODEL_ACCOUNT_AGGREGATE)

      read_model "Both" do
        include Account

        group_by :ref
        count
      end
    end

    CROWDED_COUNT_DOMAIN = proc do
      vision "x"
      generic
      instance_exec(&READ_MODEL_ACCOUNT_AGGREGATE)
      instance_exec(&READ_MODEL_ENTRY_AGGREGATE)

      read_model "Both" do
        include Account
        include Entry

        count
      end
    end

    def dispute(account:, index:, cents:)
      pay = Banking::CardPayment.authorize!(account: account, authorisation: { value: "auth-#{account}-#{index}" },
                                            amount: { cents: cents }, merchant: { value: "Shop#{index}" })
      pay.capture!
      pay.dispute!(disputed_by: "c-#{account}")
    end

    # A runtime holding the account with one disputed payment per amount.
    def account_disputed(account, amounts)
      runtime = build
      register_customer("c-#{account}", account)
      amounts.each_with_index { |cents, i| dispute(account: account, index: i, cents: cents) }
      runtime
    end

    def reduced(runtime, query, account) = runtime.query("Banking.#{query}", account: account).first[:card_payments]

    it "counts a filtered set — how many match, not which ones" do
      runtime = account_disputed("acct-count", [100, 200, 300])
      # An undisputed payment too, so a count of 3 (not 4) proves `where`
      # actually filtered rather than the read model counting everything.
      Banking::CardPayment.authorize!(account: "acct-count", authorisation: { value: "auth-undisputed" },
                                      amount: { cents: 999 }, merchant: { value: "Undisputed" })

      expect(reduced(runtime, "disputed_payment_count", "acct-count")).to eq(3)
    end

    it "counts zero for an account with nothing matching — an Integer, not nil" do
      runtime = account_disputed("acct-empty-count", [])

      expect(reduced(runtime, "disputed_payment_count", "acct-empty-count")).to eq(0)
    end

    it "takes the middle value for an ODD number of rows" do
      runtime = account_disputed("acct-median-odd", [100, 500, 300])

      expect(reduced(runtime, "disputed_payment_median", "acct-median-odd")).to eq(300)
    end

    # Averages the two middle values (300, 500), not the lower or upper
    # of the two, which a same-valued fixture couldn't distinguish.
    it "averages the two middle values for an EVEN number of rows" do
      runtime = account_disputed("acct-median-even", [500, 100, 300, 700])

      expect(reduced(runtime, "disputed_payment_median", "acct-median-even")).to eq(400.0)
    end

    it "answers nil for the median of an empty set — not zero" do
      runtime = account_disputed("acct-empty-median", [])

      expect(reduced(runtime, "disputed_payment_median", "acct-empty-median")).to be_nil
    end

    it "refuses a median field the aggregate does not declare, at query time" do
      runtime = boot_banking_bundle(extra: BAD_MEDIAN_READ_MODELS)
      register_customer("c-acct-missing-field", "acct-missing-field")

      expect { runtime.query("Banking.missing_median_field", account: "acct-missing-field") }
        .to raise_error(ArgumentError, /no_such_field.*declares no such attribute/m)
    end

    it "refuses a median field that is not numeric, at query time" do
      runtime = boot_banking_bundle(extra: BAD_MEDIAN_READ_MODELS)
      register_customer("c-acct-bad-field", "acct-bad-field")

      expect { runtime.query("Banking.bad_median_field", account: "acct-bad-field") }
        .to raise_error(ArgumentError, /merchant.*not numeric/m)
    end

    it "refuses count and median declared together" do
      expect(&domain_build("BothReductions", BOTH_REDUCTIONS_DOMAIN)).to raise_error(MALFORMED, /declares both count and median/)
    end

    it "refuses count declared together with group_by" do
      expect(&domain_build("CountAndGroup", COUNT_AND_GROUP_DOMAIN))
        .to raise_error(MALFORMED, /declares count together with group_by/)
    end

    it "refuses count declared with more than one many-side head" do
      expect(&domain_build("CrowdedCount", CROWDED_COUNT_DOMAIN))
        .to raise_error(MALFORMED, /declares count but includes 2 many-side/)
    end
  end

  # ADR 0078: sum/avg/min/max/percentile are sibling reductions to median, over the
  # same `where`-filtered CardPayment.amount field, now real corpus read models
  # (examples/banking/bluebook/customer_and_compliance_views.bluebook) — the plain
  # `build` helper above already loads them. any/all need a boolean field no aggregate
  # in this corpus declares yet, so they get their own small domain, below.
  context "with sum, avg, min, max, and percentile" do
    SUM_AND_MAX_DOMAIN = proc do
      vision "x"
      generic
      instance_exec(&READ_MODEL_ACCOUNT_AGGREGATE)

      read_model "Both" do
        include Account

        sum :ref
        max :ref
      end
    end

    def dispute_payment(account:, index:, cents:)
      pay = Banking::CardPayment.authorize!(account: account, authorisation: { value: "auth-#{account}-#{index}" },
                                            amount: { cents: cents }, merchant: { value: "Shop#{index}" })
      pay.capture!
      pay.dispute!(disputed_by: "c-#{account}")
    end

    def reduction_answers(runtime, account, names)
      names.to_h { |name| [name, runtime.query("Banking.disputed_payment_#{name}", account: account).first[:card_payments]] }
    end

    # Same four disputed amounts (and the same even-count shape) as "averages the
    # two middle values", above, so this fixture's own median (400.0) is already
    # known good — sum/avg/min/max/p95 are hand-computed against the same set.
    it "sums, averages, and finds the extremes of a filtered set" do
      runtime = build
      register_customer("c-acct-sum", "acct-sum")
      [500, 100, 300, 700].each_with_index { |cents, i| dispute_payment(account: "acct-sum", index: i, cents: cents) }

      # p95: sorted [100, 300, 500, 700]; pos = 0.95 * 3 = 2.85 -> 500 + 0.85 * (700 - 500)
      expect(reduction_answers(runtime, "acct-sum", [:total, :average, :smallest, :largest, :p95]))
        .to eq(total: 1600, average: 400.0, smallest: 100, largest: 700, p95: 670.0)
    end

    it "sums to zero and averages/extremes to nil for an empty set" do
      runtime = build
      register_customer("c-acct-sum-empty", "acct-sum-empty")

      expect(reduction_answers(runtime, "acct-sum-empty", [:total, :average, :smallest, :largest]))
        .to eq(total: 0, average: nil, smallest: nil, largest: nil)
    end

    # The full Banking boot is the fixture for this refusal; trimming it would lose
    # the real-domain shape (a genuine non-numeric field on a real aggregate).
    it "refuses a sum field that is not an Integer, at query time" do
      runtime = boot_banking_bundle(extra: BAD_SUM_READ_MODEL)
      register_customer("c-acct-bad-sum", "acct-bad-sum")

      expect { runtime.query("Banking.bad_sum_field", account: "acct-bad-sum") }
        .to raise_error(ArgumentError, /merchant.*not numeric/m)
    end

    it "refuses more than one reduction declared together" do
      expect(&domain_build("SumAndMax", SUM_AND_MAX_DOMAIN)).to raise_error(MALFORMED, /declares both sum and max/)
    end
  end

  context "with any and all" do
    # A whole fresh domain (aggregate, command, two read models) is the fixture for
    # any/all — no aggregate in the real Banking corpus has a bare boolean field yet.
    BOOLEAN_REDUCTIONS_DOMAIN = proc do
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

    let(:runtime) { boot_memory_domain("Widgets", BOOLEAN_REDUCTIONS_DOMAIN, aggregates: ["Shelf", "Widget"]) }

    before { runtime }

    def place_widgets(shelf, flags)
      Widgets::Shelf.open!(ref: { value: shelf })
      flags.each { |ref, flagged| Widgets::Widget.place!(shelf: shelf, ref: { value: ref }, flagged: { value: flagged }) }
    end

    def widgets_reduction(query, shelf) = runtime.query("Widgets.#{query}", shelf: shelf).first[:widgets]

    it "answers any/all over a boolean field", :aggregate_failures do
      place_widgets("s-mixed", "w1" => true, "w2" => false)

      expect(widgets_reduction("shelf_has_flagged", "s-mixed")).to be true
      expect(widgets_reduction("shelf_all_flagged", "s-mixed")).to be false
    end

    # `any` of nothing is false; `all` of nothing is true (the ordinary
    # `or`-identity/`and`-identity vacuous-truth reading, ADR 0078).
    it "answers the empty-set vacuous-truth cases", :aggregate_failures do
      Widgets::Shelf.open!(ref: { value: "s-empty" })

      expect(widgets_reduction("shelf_has_flagged", "s-empty")).to be false
      expect(widgets_reduction("shelf_all_flagged", "s-empty")).to be true
    end
  end
end
