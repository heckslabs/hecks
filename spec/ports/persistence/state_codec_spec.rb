require "spec_helper"
require "tmpdir"
require "sqlite3"
require_relative "../../support/persistence_legacy_fixture"

# THE STATE CODEC (Phase 2, Track A, PR A2) — one IR-driven spelling of an
# aggregate's state across the store boundary. The first half pins each
# shape the codec walks; the second decodes every A1 legacy fixture
# (spec/fixtures/persistence_legacy/, pinned as today's per-adapter decode
# by spec/ports/persistence_legacy_decode_spec.rb) through it and asserts
# ONE canonical form: old rows still decode, whichever adapter wrote them.
RSpec.describe Hecks::Ports::Persistence::StateCodec do
  def codec = described_class
  def fixture = PersistenceLegacyFixture

  let(:account_ir) { fixture.aggregate("Account") }
  let(:card_payment_ir) { fixture.aggregate("CardPayment") }

  # A value object nested in a value object, and a list of value objects
  # inside one — shapes banking does not declare.
  let(:menu_ir) do
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Hecks.bluebook("StateCodecShapes") do
        aggregate("Menu") do
          identified_by :code

          attribute :code, Code
          attribute :price, Price

          value_object("Code") { attribute :value, String }
          value_object("Price") do
            attribute :base, Money
            attribute :extras, list_of(Money)
          end
          value_object("Money") { attribute :cents, Integer }
        end
      end
    end
    registry.bluebook("StateCodecShapes").aggregate("Menu")
  end

  # ── the canonical decoded form of the two seeded records ─────────────

  let(:canonical_account) do
    {
      customer:        "CUST-1",
      number:          { value: "ACC-1" },
      balance:         { cents: 1250, currency: "USD" },
      kind:            { name: "current" },
      daily_limit:     { cents: 500 },
      ledger:          [
        { sequence: { value: 1 }, amount: { cents: 1000, currency: "USD" }, narrative: { text: "opening" },
          direction: { value: "credit" }, state: "posted" },
        { sequence: { value: 2 }, amount: { cents: 250, currency: "USD" }, narrative: { text: "top up" },
          direction: { value: "credit" }, state: "reversed" }
      ],
      fees_cents:      { cents: 0, currency: "USD" },
      interest_cents:  { cents: 0, currency: "USD" },
      status:          "open",
      customer_status: "active"
    }
  end

  let(:canonical_card_payment) do
    {
      account:        "ACC-1",
      disputed_by:    nil,
      authorisation:  { value: "AUTH-1" },
      amount:         { cents: 300 },
      merchant:       { value: "Cafe" },
      tags:           [{ value: "food" }, { value: "travel" }],
      status:         "authorized",
      account_status: "open"
    }
  end

  # A SQL head stores one column per persisted field, so a never-seeded
  # projected field arrives as a stored NULL. The codec keeps presence as
  # stored (see "absence" below); it does not invent or erase the key.
  let(:sql_head_card_payment) { canonical_card_payment.merge(account_customer_status: nil) }

  def stringify(held)
    JSON.parse(JSON.generate(held))
  end

  describe ".encode" do
    it "answers string keys at every depth, JSON-ready" do
      state = { balance: { cents: 1, currency: "USD" }, ledger: [{ amount: { cents: 2 }, state: "posted" }] }

      expect(codec.encode(account_ir, state))
        .to eq("balance" => { "cents" => 1, "currency" => "USD" },
               "ledger"  => [{ "amount" => { "cents" => 2 }, "state" => "posted" }])
    end

    it "materializes Runtime::Values, including ones inside entity-list elements" do
      live = fixture.instances.find { |instance| instance.aggregate.name == "Account" }

      encoded = codec.encode(account_ir, live.state)
      expect(encoded).to eq(stringify(live.state))
      expect(encoded.dig("ledger", 0, "amount")).to eq("cents" => 1000, "currency" => "USD")
    end

    it "leaves only JSON scalars at the leaves — a Symbol becomes its String" do
      expect(codec.encode(account_ir, { status: :open, flags: [:a, 1, 1.5, true, nil] }))
        .to eq("status" => "open", "flags" => ["a", 1, 1.5, true, nil])
    end
  end

  describe ".decode" do
    it "symbolizes declared top-level keys — attributes, the lifecycle field, projected fields" do
      raw = { "customer" => "CUST-1", "status" => "open", "customer_status" => "active" }

      expect(codec.decode(account_ir, raw)).to eq(customer: "CUST-1", status: "open", customer_status: "active")
    end

    it "symbolizes a value object's declared members" do
      expect(codec.decode(account_ir, { "balance" => { "cents" => 5, "currency" => "USD" } }))
        .to eq(balance: { cents: 5, currency: "USD" })
    end

    it "walks a value object nested in a value object, and a list of value objects inside it" do
      raw = { "price" => { "base" => { "cents" => 5 }, "extras" => [{ "cents" => 1 }, { "cents" => 2 }] } }

      expect(codec.decode(menu_ir, raw)).to eq(price: { base: { cents: 5 }, extras: [{ cents: 1 }, { cents: 2 }] })
    end

    it "symbolizes each element of a list of value objects" do
      expect(codec.decode(card_payment_ir, { "tags" => [{ "value" => "food" }] })).to eq(tags: [{ value: "food" }])
    end

    it "walks entity-list elements: their fields, their nested value objects, their own lifecycle field" do
      raw = { "ledger" => [{ "sequence" => { "value" => 1 }, "amount" => { "cents" => 9, "currency" => "USD" },
                             "state" => "posted" }] }

      expect(codec.decode(account_ir, raw))
        .to eq(ledger: [{ sequence: { value: 1 }, amount: { cents: 9, currency: "USD" }, state: "posted" }])
    end

    it "passes a reference through as the id it is, required or optional" do
      expect(codec.decode(card_payment_ir, { "account" => "ACC-1", "disputed_by" => "CUST-9" }))
        .to eq(account: "ACC-1", disputed_by: "CUST-9")
    end

    it "accepts either spelling at every depth, and mixed" do
      mixed = { balance: { "cents" => 5, currency: "USD" }, "ledger" => [{ amount: { "cents" => 1 } }] }

      expect(codec.decode(account_ir, mixed)).to eq(balance: { cents: 5, currency: "USD" }, ledger: [{ amount: { cents: 1 } }])
    end

    it "lets the symbol spelling win when one hash holds both" do
      expect(codec.decode(account_ir, { "status" => "stale", status: "open" })).to eq(status: "open")
      expect(codec.decode(account_ir, { status: "open", "status" => "stale" })).to eq(status: "open")
    end

    describe "undeclared keys (retired fields an Era translation may still read)" do
      it "keeps a retired top-level field, symbolized like every top-level key, its value untouched" do
        expect(codec.decode(account_ir, { "overdraft" => { "cents" => 1 } })).to eq(overdraft: { "cents" => 1 })
      end

      it "keeps a retired value-object member with the spelling it arrived in" do
        raw = { "price" => { "base" => { "cents" => 5, "currency" => "EUR" }, "legacy" => 1 } }

        expect(codec.decode(menu_ir, raw)).to eq(price: { base: { cents: 5, "currency" => "EUR" }, "legacy" => 1 })
      end
    end

    describe "absence" do
      it "never invents a declared key the stored state does not hold" do
        decoded = codec.decode(card_payment_ir, { "account" => "ACC-1" })

        expect(decoded).to eq(account: "ACC-1")
        expect(decoded).not_to have_key(:account_customer_status)
        expect(decoded).not_to have_key(:tags)
      end

      it "never erases a stored nil" do
        expect(codec.decode(card_payment_ir, { "disputed_by" => nil, "tags" => nil }))
          .to eq(disputed_by: nil, tags: nil)
      end

      # Why absence is the canonical form: the runtime reads it as "this
      # record predates the field" (Instance.hydrate_with_defaults, Era
      # Lineage#translate's backfill, spec/runtime/attribute_absence_spec).
      it "lets hydration still fill a declared default the record predates" do
        instance = Hecks::Runtime::Instance.new(aggregate: card_payment_ir, id: "AUTH-1",
                                                state: codec.decode(card_payment_ir, { "account" => "ACC-1" }))

        expect(instance[:status]).to eq("authorized")
      end
    end

    it "leaves a legacy non-Hash value for a value-object field for hydration to wrap" do
      expect(codec.decode(account_ir, { "number" => "ACC-1" })).to eq(number: "ACC-1")
    end

    it "answers a non-Hash raw state (a delete entry's nil) as itself" do
      expect(codec.decode(account_ir, nil)).to be_nil
    end
  end

  describe ".copy" do
    let(:live) { fixture.instances.find { |instance| instance.aggregate.name == "Account" } }

    it "is decode(encode(state)) — what a durable adapter would hand back" do
      expect(codec.copy(account_ir, live.state)).to eq(codec.decode(account_ir, codec.encode(account_ir, live.state)))
      expect(codec.copy(account_ir, live.state)).to eq(canonical_account)
    end

    it "shares no object with the state it copied" do
      copied = codec.copy(account_ir, live.state)

      expect(copied[:balance]).to be_a(Hash)
      expect(copied[:balance]).not_to equal(live.state[:balance])
      copied[:ledger].first[:amount][:cents] = 0
      expect(live.state[:ledger].first[:amount][:cents]).to eq(1000)
    end

    it "hydrates into the same Instance state the legacy top-level-only shape does" do
      legacy = stringify(live.state).transform_keys(&:to_sym)
      from_legacy = Hecks::Runtime::Instance.new(aggregate: account_ir, id: "ACC-1", state: legacy)
      from_copy = Hecks::Runtime::Instance.new(aggregate: account_ir, id: "ACC-1", state: codec.copy(account_ir, live.state))

      expect(from_copy.state).to eq(from_legacy.state)
    end
  end

  # ── every A1 legacy fixture, through the codec ───────────────────────

  describe "decoding the A1 legacy fixtures" do
    around do |example|
      @dir = Dir.mktmpdir("hecks-state-codec-")
      example.run
    ensure
      FileUtils.remove_entry(@dir) if @dir
    end

    # The raw `state:` the block's adapter call passes `Instance.new` —
    # today's per-adapter decode, the same capture A1's spec pins.
    def decoded_state
      captured = []
      allow(Hecks::Runtime::Instance).to receive(:new).and_wrap_original do |original, **kwargs|
        captured << kwargs[:state]
        original.call(**kwargs)
      end
      yield
      captured.last
    end

    # [label, aggregate IR, raw state, canonical decode] for one adapter.
    def expect_canonical(sources)
      sources.each do |label, ir, raw, expected|
        decoded = codec.decode(ir, raw)

        expect(decoded).to eq(expected), "#{label}: decoded #{decoded.inspect}"
        # The round-trip property: decoding what encode makes of a decode
        # changes nothing, and encode is exactly a JSON round trip.
        expect(codec.decode(ir, codec.encode(ir, decoded))).to eq(decoded), "#{label}: round trip"
        expect(codec.encode(ir, decoded)).to eq(stringify(decoded)), "#{label}: JSON-ready"
      end
    end

    def records
      [[account_ir, "ACC-1", canonical_account, canonical_account],
       [card_payment_ir, "AUTH-1", canonical_card_payment, sql_head_card_payment]]
    end

    it "Heki: snapshot bytes, today's find, journal lines and today's entries" do
      sources = records.flat_map do |ir, id, canonical, _|
        adapter = fixture.heki_adapter(ir, @dir)
        journal = File.readlines(File.join(fixture::DIR, "heki", "#{ir.storage_name}.heki.journal"), chomp: true)
        [["heki #{ir.name} snapshot", ir, adapter.send(:read_snapshot).fetch(id), canonical],
         ["heki #{ir.name} find", ir, decoded_state { adapter.find(id) }, canonical]] +
          journal.map { |line| ["heki #{ir.name} journal line", ir, JSON.parse(line)["state"], canonical] } +
          adapter.entries.map { |entry| ["heki #{ir.name} entries", ir, entry.state, canonical] }
      end

      expect(sources.size).to eq(8)
      expect_canonical(sources)
    end

    it "Sqlite: today's head find and entries, plus the raw journal JSON" do
      sources = records.flat_map do |ir, id, canonical, head|
        adapter = fixture.sqlite_adapter(ir, @dir)
        db = SQLite3::Database.new(File.join(@dir, "banking.sqlite3"))
        raw = db.execute(%(SELECT state FROM "#{ir.storage_name}_entries")).map { |(state)| JSON.parse(state) }
        db.close
        [["sqlite #{ir.name} find", ir, decoded_state { adapter.find(id) }, head]] +
          adapter.entries.map { |entry| ["sqlite #{ir.name} entries", ir, entry.state, canonical] } +
          raw.map { |state| ["sqlite #{ir.name} raw entry", ir, state, canonical] }
      end

      expect(sources.size).to eq(6)
      expect_canonical(sources)
    end

    it "D1: today's head find and entries, plus the dumped journal rows" do
      rows = fixture.read_json("d1/rows.json")
      sources = records.flat_map do |ir, id, canonical, head|
        adapter = fixture.d1_adapter(ir)
        [["d1 #{ir.name} find", ir, decoded_state { adapter.find(id) }, head]] +
          adapter.entries.map { |entry| ["d1 #{ir.name} entries", ir, entry.state, canonical] } +
          rows.fetch("#{ir.storage_name}_entries").map do |row|
            ["d1 #{ir.name} raw entry", ir, JSON.parse(row["state"]), canonical]
          end
      end

      expect(sources.size).to eq(6)
      expect_canonical(sources)
    end

    it "Postgres: today's head codec over the dumped rows, and the journal both raw and top-level-symbolized" do
      rows = fixture.read_json("postgres/rows.json")
      sources = records.flat_map do |ir, _, canonical, head|
        held = rows.fetch(ir.storage_name)
        journal = held.fetch("entries").map { |row| JSON.parse(row["state"]) }
        [["postgres #{ir.name} head", ir, fixture.codec(Hecks::Adapters::Postgres, ir).send(:decode, held["head"][0]), head]] +
          journal.map { |state| ["postgres #{ir.name} raw entry", ir, state, canonical] } +
          journal.map { |state| ["postgres #{ir.name} entries", ir, state.transform_keys(&:to_sym), canonical] }
      end

      expect(sources.size).to eq(6)
      expect_canonical(sources)
    end

    it "PostgresEra: head_snapshot through today's codec and raw, and the journal raw and top-level-symbolized" do
      rows = fixture.read_json("postgres_era/rows.json")
      sources = records.flat_map do |ir, _, canonical, _|
        held = rows.fetch(ir.storage_name)
        snapshot = held.dig("head_snapshot", 0, "state")
        journal = held.fetch("journal").map { |row| JSON.parse(row["state"]) }
        [["postgres_era #{ir.name} head", ir, fixture.codec(Hecks::Adapters::PostgresEra, ir).send(:decode, snapshot), canonical],
         ["postgres_era #{ir.name} raw head", ir, JSON.parse(snapshot), canonical]] +
          journal.map { |state| ["postgres_era #{ir.name} raw journal", ir, state, canonical] } +
          journal.map { |state| ["postgres_era #{ir.name} entries", ir, state.transform_keys(&:to_sym), canonical] }
      end

      expect(sources.size).to eq(8)
      expect_canonical(sources)
    end

    it "Memory: copying each seeded live state lands on the same canonical form" do
      fixture.instances.each do |instance|
        expected = instance.aggregate.name == "Account" ? canonical_account : canonical_card_payment

        expect(codec.copy(instance.aggregate, instance.state)).to eq(expected)
      end
    end
  end
end
