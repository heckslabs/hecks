require "spec_helper"
require "tmpdir"
require "hecks/ports/persistence/plugins/era"
require_relative "../support/persistence_legacy_fixture"
require_relative "../support/postgres_probe"

# THE CHARACTERIZATION BASELINE A2's STATE CODEC IS HELD TO (Phase 2,
# Track A, PR A1). Each example decodes a COMMITTED fixture under
# spec/fixtures/persistence_legacy/ — written by the real adapter, see
# bin/regenerate_persistence_legacy_fixtures — through TODAY'S adapter,
# and pins exactly what comes out, key-type inconsistencies included.
#
# WHAT IS PINNED is the raw `state:` each adapter hands
# `Runtime::Instance.new` (captured below), not `instance.state`
# afterwards: `Instance#initialize` re-hydrates state into `Value`s,
# which reads either key spelling (runtime/value/coercion.rb) and so
# hides exactly the inconsistency this file exists to record. Journal
# `entries` build a plain `Entry`, so their `state` is pinned as-is.
#
# Every place marked "A2 normalizes this" is a difference A2's codec
# must remove (declared keys become symbols at every depth) while
# still DECODING these exact legacy bytes. When A3 routes the adapters
# through the codec, those expectations flip to the deep-symbol shape —
# the fixtures themselves must not change.
RSpec.describe "legacy persistence decode (A1 baseline)" do
  def fixture = PersistenceLegacyFixture

  # ── the four decoded shapes the adapters produce today ───────────────

  def ledger(keys)
    [
      { keys.call(:sequence) => { keys.call(:value) => 1 },
        keys.call(:amount) => { keys.call(:cents) => 1000, keys.call(:currency) => "USD" },
        keys.call(:narrative) => { keys.call(:text) => "opening" },
        keys.call(:direction) => { keys.call(:value) => "credit" }, keys.call(:state) => "posted" },
      { keys.call(:sequence) => { keys.call(:value) => 2 },
        keys.call(:amount) => { keys.call(:cents) => 250, keys.call(:currency) => "USD" },
        keys.call(:narrative) => { keys.call(:text) => "top up" },
        keys.call(:direction) => { keys.call(:value) => "credit" }, keys.call(:state) => "reversed" }
    ]
  end

  # `nested:` picks the spelling BELOW the top level — `:to_s` is today's
  # "top-level symbols, nested strings" shape; `:to_sym` is deep symbols.
  def account(nested:)
    keys = nested.to_proc
    {
      customer:        "CUST-1",
      number:          { keys.call(:value) => "ACC-1" },
      balance:         { keys.call(:cents) => 1250, keys.call(:currency) => "USD" },
      kind:            { keys.call(:name) => "current" },
      daily_limit:     { keys.call(:cents) => 500 },
      ledger:          ledger(keys),
      fees_cents:      { keys.call(:cents) => 0, keys.call(:currency) => "USD" },
      interest_cents:  { keys.call(:cents) => 0, keys.call(:currency) => "USD" },
      status:          "open",
      customer_status: "active"
    }
  end

  def card_payment(nested:)
    keys = nested.to_proc
    {
      account:        "ACC-1",
      disputed_by:    nil,
      authorisation:  { keys.call(:value) => "AUTH-1" },
      amount:         { keys.call(:cents) => 300 },
      merchant:       { keys.call(:value) => "Cafe" },
      tags:           [{ keys.call(:value) => "food" }, { keys.call(:value) => "travel" }],
      status:         "authorized",
      account_status: "open"
    }
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

  def entry_states(adapter) = adapter.entries.map(&:state)

  around do |example|
    @dir = Dir.mktmpdir("hecks-persistence-legacy-")
    example.run
  ensure
    FileUtils.remove_entry(@dir) if @dir
  end

  let(:account_ir) { fixture.aggregate("Account") }
  let(:card_payment_ir) { fixture.aggregate("CardPayment") }

  describe "Heki (snapshot + journal)" do
    it "decodes the snapshot with only TOP-LEVEL keys symbolized" do
      adapter = fixture.heki_adapter(account_ir, @dir)
      # A2 normalizes this: value-object members and list elements
      # (Money, LedgerEntry and its nested VOs) stay STRING-keyed.
      expect(decoded_state { adapter.find("ACC-1") }).to eq(account(nested: :to_s))
    end

    it "decodes a list of value objects string-keyed inside" do
      adapter = fixture.heki_adapter(card_payment_ir, @dir)
      # A2 normalizes this: `tags` elements stay STRING-keyed.
      # (No `account_customer_status` key at all — Heki holds only what
      # was written; the never-seeded projected field is simply absent.)
      expect(decoded_state { adapter.find("AUTH-1") }).to eq(card_payment(nested: :to_s))
    end

    it "decodes journal entries with only top-level keys symbolized" do
      # A2 normalizes this: nested keys stay STRING-keyed.
      expect(entry_states(fixture.heki_adapter(account_ir, @dir))).to eq([account(nested: :to_s)])
      expect(entry_states(fixture.heki_adapter(card_payment_ir, @dir))).to eq([card_payment(nested: :to_s)])
    end
  end

  describe "Sqlite (rows)" do
    it "decodes head columns with DEEP symbol keys" do
      expect(decoded_state { fixture.sqlite_adapter(account_ir, @dir).find("ACC-1") }).to eq(account(nested: :to_sym))
    end

    it "decodes a never-seeded projected field as a present nil" do
      # A2 normalizes this: SQL heads carry every persisted column, so an
      # unseeded `projects` field reads back as `nil` here but is ABSENT
      # under Heki/PostgresEra.
      expect(decoded_state { fixture.sqlite_adapter(card_payment_ir, @dir).find("AUTH-1") })
        .to eq(card_payment(nested: :to_sym).merge(account_customer_status: nil))
    end

    it "decodes journal entries with only top-level keys symbolized" do
      # A2 normalizes this: the entries reader (sqlite.rb#entries)
      # symbolizes one level, unlike this same adapter's own head decode.
      expect(entry_states(fixture.sqlite_adapter(account_ir, @dir))).to eq([account(nested: :to_s)])
      expect(entry_states(fixture.sqlite_adapter(card_payment_ir, @dir))).to eq([card_payment(nested: :to_s)])
    end
  end

  describe "D1 (rows, SQLite behind its HTTP transport)" do
    it "decodes head columns with DEEP symbol keys (Sqlite::Codec, shared)" do
      expect(decoded_state { fixture.d1_adapter(account_ir).find("ACC-1") }).to eq(account(nested: :to_sym))
      # A2 normalizes this: the unseeded projected field is a present nil.
      expect(decoded_state { fixture.d1_adapter(card_payment_ir).find("AUTH-1") })
        .to eq(card_payment(nested: :to_sym).merge(account_customer_status: nil))
    end

    it "decodes journal entries with only top-level keys symbolized" do
      # A2 normalizes this: nested keys stay STRING-keyed (d1.rb#entries).
      expect(entry_states(fixture.d1_adapter(account_ir))).to eq([account(nested: :to_s)])
      expect(entry_states(fixture.d1_adapter(card_payment_ir))).to eq([card_payment(nested: :to_s)])
    end
  end

  # The codecs alone, over the exact rows `pg` returned when the fixture
  # was written — no connection, so these run in the default suite.
  describe "Postgres / PostgresEra codecs (rows as pg returned them)" do
    it "Postgres decodes head rows with DEEP symbol keys" do
      rows = fixture.read_json("postgres/rows.json")
      codec = ->(ir) { fixture.codec(Hecks::Adapters::Postgres, ir) }

      expect(codec.call(account_ir).send(:decode, rows.dig("account", "head", 0))).to eq(account(nested: :to_sym))
      # A2 normalizes this: the unseeded projected field is a present nil.
      expect(codec.call(card_payment_ir).send(:decode, rows.dig("card_payment", "head", 0)))
        .to eq(card_payment(nested: :to_sym).merge(account_customer_status: nil))
    end

    it "PostgresEra decodes head_snapshot state with DEEP symbol keys" do
      rows = fixture.read_json("postgres_era/rows.json")
      codec = ->(ir) { fixture.codec(Hecks::Adapters::PostgresEra, ir) }

      expect(codec.call(account_ir).send(:decode, rows.dig("account", "head_snapshot", 0, "state")))
        .to eq(account(nested: :to_sym))
      # A2 normalizes this: one jsonb blob holds only what was written, so
      # the unseeded projected field is ABSENT (the Postgres head has nil).
      expect(codec.call(card_payment_ir).send(:decode, rows.dig("card_payment", "head_snapshot", 0, "state")))
        .to eq(card_payment(nested: :to_sym))
    end
  end

  describe "Memory (never serializes)" do
    it "hands back a SHALLOW copy of whatever state object was saved" do
      adapter = Hecks::Adapters::Memory.new(aggregate: card_payment_ir)
      saved = fixture.instances.find { |instance| instance.aggregate.name == "CardPayment" }

      state = decoded_state { adapter.save(saved) }
      # A2 normalizes this: no encode/decode at all — nested values are the
      # very same objects the caller saved (`state.dup` is one level deep).
      expect(state).not_to equal(saved.state)
      expect(state[:amount]).to equal(saved.state[:amount])
    end
  end

  describe "against a real Postgres", :io do
    def databases
      {
        postgres:     "hecks_persistence_legacy_decode_spec",
        postgres_era: "hecks_persistence_legacy_decode_era_spec"
      }
    end

    before(:all) do
      skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

      admin = PG.connect(dbname: "postgres")
      databases.each_value do |name|
        admin.exec("DROP DATABASE IF EXISTS #{name} WITH (FORCE)")
        admin.exec("CREATE DATABASE #{name}")
      end
      admin.close
    end

    after(:all) do
      next unless PostgresProbe.available?

      admin = PG.connect(dbname: "postgres")
      databases.each_value { |name| admin.exec("DROP DATABASE IF EXISTS #{name} WITH (FORCE)") }
      admin.close
    end

    before do
      databases.each_value do |name|
        scrub = PG.connect(dbname: name)
        scrub.exec("DROP SCHEMA public CASCADE")
        scrub.exec("CREATE SCHEMA public")
        scrub.close
      end
    end

    it "Postgres: restored rows decode deep on find, top-level-only on entries" do
      adapter = fixture.postgres_adapter(account_ir, databases[:postgres])

      expect(decoded_state { adapter.find("ACC-1") }).to eq(account(nested: :to_sym))
      # A2 normalizes this: postgres.rb#entries symbolizes one level only.
      expect(entry_states(adapter)).to eq([account(nested: :to_s)])

      payments = fixture.postgres_adapter(card_payment_ir, databases[:postgres])
      # A2 normalizes this: the unseeded projected field is a present nil.
      expect(decoded_state { payments.find("AUTH-1") })
        .to eq(card_payment(nested: :to_sym).merge(account_customer_status: nil))
      expect(entry_states(payments)).to eq([card_payment(nested: :to_s)])
    end

    it "PostgresEra: restored journal + head_snapshot decode deep on find, top-level-only on entries" do
      adapter = fixture.postgres_era_adapter(account_ir, databases[:postgres_era])

      expect(decoded_state { adapter.find("ACC-1") }).to eq(account(nested: :to_sym))
      # A2 normalizes this: postgres_era.rb#entries symbolizes one level only.
      expect(entry_states(adapter)).to eq([account(nested: :to_s)])

      payments = fixture.postgres_era_adapter(card_payment_ir, databases[:postgres_era])
      # A2 normalizes this: the unseeded projected field is ABSENT here.
      expect(decoded_state { payments.find("AUTH-1") }).to eq(card_payment(nested: :to_sym))
      expect(entry_states(payments)).to eq([card_payment(nested: :to_s)])
    end
  end
end
