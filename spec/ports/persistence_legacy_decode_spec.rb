require "spec_helper"
require "tmpdir"
require "hecks/ports/persistence/plugins/era"
require_relative "../support/persistence_legacy_fixture"
require_relative "../support/postgres_probe"

# **The legacy bytes still decode** — now canonically (Phase 2, Track A).
# Each example decodes a committed fixture under
# spec/fixtures/persistence_legacy/ — written by the real adapter before
# the state codec existed, see bin/regenerate_persistence_legacy_fixtures
# (PR A1) — through today's adapter, and pins exactly what comes out.
#
# A1 pinned the per-adapter inconsistencies those bytes once decoded
# into: Heki and every journal reader symbolized the top level only,
# the SQL heads symbolized deep, Memory kept a shallow `state.dup`, and a
# never-seeded projected field read back as a present nil on the SQL
# heads but absent on Heki/PostgresEra. A3 routed every adapter through
# `Ports::Persistence::StateCodec`, so every one of those differences is
# gone: one deep-symbol shape, from every adapter, for head reads and
# journal `entries` alike. The fixtures themselves are unchanged — only
# what they decode to changed.
#
# What is pinned is the raw `state:` each adapter hands
# `Runtime::Instance.new` (captured below), not `instance.state`
# afterwards: `Instance#initialize` re-hydrates state into `Value`s, and
# a value object's own fields still accept either spelling on that input
# door (runtime/value/coercion.rb `fields_for`), so reading `state`
# afterwards would hide a nested regression back to the old shapes. Journal `entries`
# build a plain `Entry`, so their `state` is pinned as-is.
RSpec.describe "legacy persistence decode (A1 bytes, A3 canonical decode)" do
  def fixture = PersistenceLegacyFixture

  # ── the one decoded shape every adapter produces ─────────────────────

  def account
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

  # No `account_customer_status` key at all, from any adapter: the
  # projected field was never seeded, and a NULL projected-only column
  # now reads back absent (Sqlite::Codec#projected_only?), matching
  # Heki/PostgresEra's single blob.
  def card_payment
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
    it "decodes the snapshot DEEP — value-object members and entity-list elements included" do
      adapter = fixture.heki_adapter(account_ir, @dir)
      expect(decoded_state { adapter.find("ACC-1") }).to eq(account)
    end

    it "decodes a list of value objects symbol-keyed inside, with the unseeded projected field absent" do
      adapter = fixture.heki_adapter(card_payment_ir, @dir)
      expect(decoded_state { adapter.find("AUTH-1") }).to eq(card_payment)
    end

    it "decodes journal entries to the same shape as the snapshot" do
      expect(entry_states(fixture.heki_adapter(account_ir, @dir))).to eq([account])
      expect(entry_states(fixture.heki_adapter(card_payment_ir, @dir))).to eq([card_payment])
    end
  end

  describe "Sqlite (rows)" do
    it "decodes head columns DEEP" do
      expect(decoded_state { fixture.sqlite_adapter(account_ir, @dir).find("ACC-1") }).to eq(account)
    end

    it "reads a never-seeded projected field's NULL column back ABSENT, as Heki/PostgresEra do" do
      expect(decoded_state { fixture.sqlite_adapter(card_payment_ir, @dir).find("AUTH-1") }).to eq(card_payment)
    end

    it "decodes journal entries to the same shape as its own head" do
      expect(entry_states(fixture.sqlite_adapter(account_ir, @dir))).to eq([account])
      expect(entry_states(fixture.sqlite_adapter(card_payment_ir, @dir))).to eq([card_payment])
    end
  end

  describe "D1 (rows, SQLite behind its HTTP transport)" do
    it "decodes head columns DEEP (Sqlite::Codec, shared), the projected field absent" do
      expect(decoded_state { fixture.d1_adapter(account_ir).find("ACC-1") }).to eq(account)
      expect(decoded_state { fixture.d1_adapter(card_payment_ir).find("AUTH-1") }).to eq(card_payment)
    end

    it "decodes journal entries to the same shape as its own head" do
      expect(entry_states(fixture.d1_adapter(account_ir))).to eq([account])
      expect(entry_states(fixture.d1_adapter(card_payment_ir))).to eq([card_payment])
    end
  end

  # The codecs alone, over the exact rows `pg` returned when the fixture
  # was written — no connection, so these run in the default suite.
  describe "Postgres / PostgresEra codecs (rows as pg returned them)" do
    it "Postgres decodes head rows DEEP, the projected field's NULL column absent" do
      rows = fixture.read_json("postgres/rows.json")
      codec = ->(ir) { fixture.codec(Hecks::Adapters::Postgres, ir) }

      expect(codec.call(account_ir).send(:decode, rows.dig("account", "head", 0))).to eq(account)
      expect(codec.call(card_payment_ir).send(:decode, rows.dig("card_payment", "head", 0))).to eq(card_payment)
    end

    it "PostgresEra decodes head_snapshot state DEEP, the projected field absent" do
      rows = fixture.read_json("postgres_era/rows.json")
      codec = ->(ir) { fixture.codec(Hecks::Adapters::PostgresEra, ir) }

      expect(codec.call(account_ir).send(:decode, rows.dig("account", "head_snapshot", 0, "state"))).to eq(account)
      expect(codec.call(card_payment_ir).send(:decode, rows.dig("card_payment", "head_snapshot", 0, "state")))
        .to eq(card_payment)
    end
  end

  describe "Memory (copies through the codec)" do
    it "hands back a DEEP copy in the same canonical shape, sharing no object with what was saved" do
      adapter = Hecks::Adapters::Memory.new(aggregate: card_payment_ir)
      saved = fixture.instances.find { |instance| instance.aggregate.name == "CardPayment" }

      state = decoded_state { adapter.save(saved) }
      expect(state).to eq(card_payment)
      expect(state[:amount]).not_to equal(saved.state[:amount])
      expect(entry_states(adapter)).to eq([card_payment])
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

    it "Postgres: restored rows decode deep on find AND on entries" do
      adapter = fixture.postgres_adapter(account_ir, databases[:postgres])

      expect(decoded_state { adapter.find("ACC-1") }).to eq(account)
      expect(entry_states(adapter)).to eq([account])

      payments = fixture.postgres_adapter(card_payment_ir, databases[:postgres])
      expect(decoded_state { payments.find("AUTH-1") }).to eq(card_payment)
      expect(entry_states(payments)).to eq([card_payment])
    end

    it "PostgresEra: restored journal + head_snapshot decode deep on find AND on entries" do
      adapter = fixture.postgres_era_adapter(account_ir, databases[:postgres_era])

      expect(decoded_state { adapter.find("ACC-1") }).to eq(account)
      expect(entry_states(adapter)).to eq([account])

      payments = fixture.postgres_era_adapter(card_payment_ir, databases[:postgres_era])
      expect(decoded_state { payments.find("AUTH-1") }).to eq(card_payment)
      expect(entry_states(payments)).to eq([card_payment])
    end
  end
end
