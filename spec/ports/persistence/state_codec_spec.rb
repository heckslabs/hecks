require "spec_helper"
require "tmpdir"
require "sqlite3"
require_relative "../../support/persistence_legacy_fixture"

# The state Codec: pins each shape it walks, then decodes every legacy fixture through it
# and asserts one canonical form regardless of which adapter wrote the row.
RSpec.describe Hecks::Ports::Persistence::StateCodec do
  def codec = described_class
  def fixture = PersistenceLegacyFixture

  def account_ir = fixture.aggregate("Account")
  def card_payment_ir = fixture.aggregate("CardPayment")

  # A value object nested in a value object, and a list of value objects inside one.
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

    it "materializes Runtime::Values, including ones inside entity-list elements", :aggregate_failures do
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

    it "lets the symbol spelling win when one hash holds both", :aggregate_failures do
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
      it "never invents a declared key the stored state does not hold", :aggregate_failures do
        decoded = codec.decode(card_payment_ir, { "account" => "ACC-1" })

        expect(decoded).to eq(account: "ACC-1")
        expect(decoded).not_to have_key(:account_customer_status)
        expect(decoded).not_to have_key(:tags)
      end

      it "never erases a stored nil" do
        expect(codec.decode(card_payment_ir, { "disputed_by" => nil, "tags" => nil }))
          .to eq(disputed_by: nil, tags: nil)
      end

      # Absence is canonical: the runtime reads it as "this record predates the field".
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

  describe ".decoded?" do
    let(:decoded_menu) do
      { code: { value: "M1" }, price: { base: { cents: 1 }, extras: [{ cents: 2 }, { cents: 3 }] } }
    end

    it "accepts the shape decode produces, list elements included" do
      expect(codec.decoded?(menu_ir, decoded_menu)).to be(true)
    end

    it "refuses a string key in any element of a list of value objects" do
      raw = decoded_menu.merge(price: { base: { cents: 1 }, extras: [{ cents: 2 }, { "cents" => 3 }] })

      expect(codec.decoded?(menu_ir, raw)).to be(false)
    end

    it "agrees with decode: whatever decode respells, decoded? refuses, and its output passes",
       :aggregate_failures do
      raw = { "code" => { "value" => "M1" }, "price" => { "base" => { "cents" => 1 }, "extras" => [{ "cents" => 2 }] } }

      expect(codec.decoded?(menu_ir, raw)).to be(false)
      expect(codec.decoded?(menu_ir, codec.decode(menu_ir, raw))).to be(true)
    end

    it "passes a list's non-Hash elements and an unresolvable element type without looking further" do
      raw = decoded_menu.merge(price: { base: { cents: 1 }, extras: [1, nil, "x"] })

      expect(codec.decoded?(menu_ir, raw)).to be(true)
    end

    it "resolves a list's element type once, however many elements the list holds" do
      # Once for the `base` field, once for the whole `extras` list.
      allow(Hecks::Runtime::Value).to receive(:value_object_for).and_call_original
      raw = decoded_menu.merge(price: { base: { cents: 1 }, extras: Array.new(5) { { cents: 1 } } })

      codec.decoded?(menu_ir, raw)

      expect(Hecks::Runtime::Value).to have_received(:value_object_for).with(anything, "Money").twice
    end
  end

  describe ".copy" do
    let(:live) { fixture.instances.find { |instance| instance.aggregate.name == "Account" } }

    it "is decode(encode(state)) — what a durable adapter would hand back", :aggregate_failures do
      expect(codec.copy(account_ir, live.state)).to eq(codec.decode(account_ir, codec.encode(account_ir, live.state)))
      expect(codec.copy(account_ir, live.state)).to eq(canonical_account)
    end

    it "shares no object with the state it copied", :aggregate_failures do
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

  describe "decoding the A1 legacy fixtures" do
    around do |example|
      @dir = Dir.mktmpdir("hecks-state-codec-")
      example.run
    ensure
      FileUtils.remove_entry(@dir) if @dir
    end

    # The raw `state:` the block's adapter call passes `Instance.new`.
    def decoded_state
      captured = []
      allow(Hecks::Runtime::Instance).to receive(:new).and_wrap_original do |original, **kwargs|
        captured << kwargs[:state]
        original.call(**kwargs)
      end
      yield
      captured.last
    end

    # [label, aggregate IR, raw state, canonical decode] for one adapter; a SQL head's
    # NULL projected column reads back absent, so every source lands on one form.
    def expect_canonical(sources)
      sources.each { |label, ir, raw, expected| expect_source_canonical(label, ir, raw, expected) }
    end

    def expect_source_canonical(label, model, raw, expected)
      decoded = codec.decode(model, raw)

      expect(decoded).to eq(expected), "#{label}: decoded #{decoded.inspect}"
      expect_round_trip(label, model, decoded)
    end

    # decode of an encode changes nothing, and encode is a JSON round trip
    def expect_round_trip(label, model, decoded)
      expect(codec.decode(model, codec.encode(model, decoded))).to eq(decoded), "#{label}: round trip"
      expect(codec.encode(model, decoded)).to eq(stringify(decoded)), "#{label}: JSON-ready"
    end

    def records
      [[account_ir, "ACC-1", canonical_account, canonical_account],
       [card_payment_ir, "AUTH-1", canonical_card_payment, canonical_card_payment]]
    end

    # One `[label, aggregate IR, raw state, canonical decode]` row per raw state.
    def labelled(tag, kind, model, states, expected)
      states.map { |state| ["#{tag} #{kind}", model, state, expected] }
    end

    def entry_states(adapter) = adapter.entries.map(&:state)

    def parsed_states(rows) = rows.map { |row| JSON.parse(row["state"]) }

    def symbolized(states) = states.map { |state| state.transform_keys(&:to_sym) }

    def heki_sources
      records.flat_map { |ir, id, canonical, _| heki_record_sources(ir, id, canonical) }
    end

    def heki_record_sources(model, id, canonical)
      adapter = fixture.heki_adapter(model, @dir)
      tag = "heki #{model.name}"
      labelled(tag, "snapshot", model, [adapter.send(:read_snapshot).fetch(id)], canonical) +
        labelled(tag, "find", model, [decoded_state { adapter.find(id) }], canonical) +
        labelled(tag, "journal line", model, heki_journal_states(model), canonical) +
        labelled(tag, "entries", model, entry_states(adapter), canonical)
    end

    def heki_journal_states(model)
      path = File.join(fixture::DIR, "heki", "#{model.storage_name}.heki.journal")
      File.readlines(path, chomp: true).map { |line| JSON.parse(line)["state"] }
    end

    def sqlite_sources
      records.flat_map { |ir, id, canonical, head| sqlite_record_sources(ir, id, canonical, head) }
    end

    def sqlite_record_sources(model, id, canonical, head)
      adapter = fixture.sqlite_adapter(model, @dir)
      raw = sqlite_raw_entries(model)
      tag = "sqlite #{model.name}"
      labelled(tag, "find", model, [decoded_state { adapter.find(id) }], head) +
        labelled(tag, "entries", model, entry_states(adapter), canonical) +
        labelled(tag, "raw entry", model, raw, canonical)
    end

    def sqlite_raw_entries(model)
      db = SQLite3::Database.new(File.join(@dir, "banking.sqlite3"))
      raw = db.execute(%(SELECT state FROM "#{model.storage_name}_entries")).map { |(state)| JSON.parse(state) }
      db.close
      raw
    end

    def d1_sources
      rows = fixture.read_json("d1/rows.json")
      records.flat_map { |ir, id, canonical, head| d1_record_sources(rows, ir, id, canonical, head) }
    end

    def d1_record_sources(rows, model, id, canonical, head)
      adapter = fixture.d1_adapter(model)
      raw = parsed_states(rows.fetch("#{model.storage_name}_entries"))
      tag = "d1 #{model.name}"
      labelled(tag, "find", model, [decoded_state { adapter.find(id) }], head) +
        labelled(tag, "entries", model, entry_states(adapter), canonical) +
        labelled(tag, "raw entry", model, raw, canonical)
    end

    def postgres_sources
      rows = fixture.read_json("postgres/rows.json")
      records.flat_map { |ir, _, canonical, head| postgres_record_sources(rows, ir, canonical, head) }
    end

    def postgres_record_sources(rows, model, canonical, head)
      held = rows.fetch(model.storage_name)
      journal = parsed_states(held.fetch("entries"))
      head_state = fixture.codec(Hecks::Adapters::Postgres, model).send(:decode, held["head"][0])
      tag = "postgres #{model.name}"
      labelled(tag, "head", model, [head_state], head) +
        labelled(tag, "raw entry", model, journal, canonical) +
        labelled(tag, "entries", model, symbolized(journal), canonical)
    end

    def postgres_era_sources
      rows = fixture.read_json("postgres_era/rows.json")
      records.flat_map { |ir, _, canonical, _| postgres_era_record_sources(rows, ir, canonical) }
    end

    def postgres_era_head(model, snapshot)
      fixture.codec(Hecks::Adapters::PostgresEra, model).send(:decode, snapshot)
    end

    def postgres_era_record_sources(rows, model, canonical)
      held = rows.fetch(model.storage_name)
      snapshot = held.dig("head_snapshot", 0, "state")
      journal = parsed_states(held.fetch("journal"))
      tag = "postgres_era #{model.name}"
      labelled(tag, "head", model, [postgres_era_head(model, snapshot)], canonical) +
        labelled(tag, "raw head", model, [JSON.parse(snapshot)], canonical) +
        labelled(tag, "raw journal", model, journal, canonical) +
        labelled(tag, "entries", model, symbolized(journal), canonical)
    end

    it "Heki: snapshot bytes, today's find, journal lines and today's entries" do
      sources = heki_sources
      expect(sources.size).to eq(8)
      expect_canonical(sources)
    end

    it "Sqlite: today's head find and entries, plus the raw journal JSON" do
      sources = sqlite_sources
      expect(sources.size).to eq(6)
      expect_canonical(sources)
    end

    it "D1: today's head find and entries, plus the dumped journal rows" do
      sources = d1_sources
      expect(sources.size).to eq(6)
      expect_canonical(sources)
    end

    it "Postgres: today's head codec over the dumped rows, and the journal both raw and top-level-symbolized" do
      sources = postgres_sources
      expect(sources.size).to eq(6)
      expect_canonical(sources)
    end

    it "PostgresEra: head_snapshot through today's codec and raw, and the journal raw and top-level-symbolized" do
      sources = postgres_era_sources
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
