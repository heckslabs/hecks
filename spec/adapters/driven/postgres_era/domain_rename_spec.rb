require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../../support/postgres_probe"
require_relative "../../../support/fenced_owner"
require_relative "../../../support/era_registry_loading"
require_relative "../../../support/era_app_role"

# `formerly_known_as`: the storage layer carries a renamed domain's history forward.
# Runs only when a Postgres server is reachable (support/postgres_probe.rb).
RSpec.describe "domain rename (formerly_known_as) in the PostgresEra adapter", :io do
  include EraRegistryLoading
  include EraAppRole

  RENAME_DB = "hecks_domain_rename_spec".freeze
  RENAME_ROLE = "hecks_domain_rename_spec_app".freeze

  OLD_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "OldName" do
      aggregate "Acct" do
        identified_by :number
        attribute :number, AccountNumber
        attribute :balance, Money

        value_object "AccountNumber" do
          attribute :value, String
        end

        value_object "Money" do
          attribute :cents, Integer
        end
      end
    end
  BLUEBOOK

  # Same shape as OLD_SOURCE; only the domain name changed.
  NEW_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "NewName" do
      formerly_known_as "OldName"

      aggregate "Acct" do
        identified_by :number
        attribute :number, AccountNumber
        attribute :balance, Money

        value_object "AccountNumber" do
          attribute :value, String
        end

        value_object "Money" do
          attribute :cents, Integer
        end
      end
    end
  BLUEBOOK

  # Renamed, plus a new field with no counterpart in the old shape.
  NEW_SOURCE_CHANGED = <<~BLUEBOOK.freeze
    Hecks.bluebook "NewName" do
      formerly_known_as "OldName"

      aggregate "Acct" do
        identified_by :number
        attribute :number, AccountNumber
        attribute :balance, Money
        attribute :note, Note

        value_object "AccountNumber" do
          attribute :value, String
        end

        value_object "Money" do
          attribute :cents, Integer
        end

        value_object "Note" do
          attribute :text, String
        end
      end
    end
  BLUEBOOK

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{RENAME_DB} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{RENAME_DB}")
    admin.close
    # PostgresEra refuses to boot as a superuser; see support/fenced_owner.rb
    FencedOwner.own!(RENAME_DB)
  end

  after(:all) do
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{RENAME_DB} WITH (FORCE)")
    admin.close
  end

  before do
    scrub = PG.connect(dbname: RENAME_DB)
    scrub.exec("DROP SCHEMA public CASCADE")
    scrub.exec("CREATE SCHEMA public")
    scrub.close
    FencedOwner.own_public!(RENAME_DB)
  end

  def app_role_database = RENAME_DB
  def app_role_name = RENAME_ROLE

  def check!(source, translation_source: nil, role: nil)
    registry = load_registry(source, translation_source: translation_source)
    bluebook = registry.bluebooks.values.first
    settings = { database: FencedOwner.url(RENAME_DB) }
    settings[:role] = role if role
    Hecks::Adapters::PostgresEra::LineageManager.check!(
      registry: registry, bluebook: bluebook, current_text: source, settings: settings
    )
    registry
  end

  def hash_of(source)
    registry = load_registry(source)
    Hecks::Runtime::StorageShape.mint_hash(registry.bluebooks.values.first)
  end

  def label_of(source) = hash_of(source)[0, 6]

  def journal_name(domain) = "hecks_journal_#{Hecks::Naming.snake(domain)}"

  def to_regclass(db, relation)
    db.exec_params("SELECT to_regclass($1)", [relation])[0]["to_regclass"]
  end

  def adapter_for(registry, aggregate_name, domain:)
    aggregate = registry.bluebooks.values.first.aggregate(aggregate_name)
    Hecks::Adapters::PostgresEra.new(aggregate: aggregate, settings: { database: RENAME_DB, domain: domain })
  end

  def write_old_record
    registry = check!(OLD_SOURCE)
    adapter = adapter_for(registry, "Acct", domain: "OldName")
    adapter.save(Hecks::Runtime::Instance.new(
                   aggregate: registry.bluebooks.values.first.aggregate("Acct"), id: "a1",
                   state: { number: { "value" => "a1" }, balance: { "cents" => 500 } }
                 ))
  end

  # Whether each relation named exists, in order.
  def presence(*names)
    with_pg(dbname: RENAME_DB) { |db| names.map { |name| !to_regclass(db, name).nil? } }
  end

  # The count of rows `table` holds for `domain`, as Postgres spells it.
  def count_in(table, domain)
    with_pg(dbname: RENAME_DB) { |db| db.exec("SELECT count(*) FROM #{table} WHERE domain = '#{domain}'")[0]["count"] }
  end

  context "with the old record written, and the same shape booted under the new name" do
    before do
      write_old_record
      @registry = check!(NEW_SOURCE)
    end

    it "boots as a quiet reboot — same shape under a new name mints no new era" do
      expect(@registry.resolved_eras["NewName"]).to eq(1)
    end

    it "leaves no era under the old name, and one under the new", :aggregate_failures do
      expect(count_in("hecks_eras", "OldName")).to eq("0")
      expect(with_pg(dbname: RENAME_DB) { |db| db.exec("SELECT ordinal FROM hecks_eras WHERE domain = 'NewName'").values })
        .to eq([["1"]])
    end

    it "still finds the record under the new name" do
      expect(adapter_for(@registry, "Acct", domain: "NewName").find("a1").balance.to_h).to eq(cents: 500)
    end

    it "physically renames the journal — the old name is gone" do
      expect(presence(journal_name("OldName"), journal_name("NewName"))).to eq([false, true])
    end

    it "physically renames the journal's era partition — the old name is gone" do
      expect(presence("#{journal_name("OldName")}_era_1", "#{journal_name("NewName")}_era_1")).to eq([false, true])
    end

    it "physically renames the journal's sequence — the old name is gone" do
      expect(presence("#{journal_name("OldName")}_ordinal", "#{journal_name("NewName")}_ordinal")).to eq([false, true])
    end

    # Writes a second row into the renamed journal, and answers the ordinals it holds.
    def ordinals_after_a_second_write
      with_pg(dbname: RENAME_DB) do |db|
        db.exec_params(
          "INSERT INTO #{journal_name("NewName")} (era, aggregate, aggregate_id, operation, state) " \
          "VALUES (1, 'acct', 'a2', 'save', '{}'::jsonb)"
        )
        db.exec("SELECT ordinal FROM #{journal_name("NewName")} ORDER BY ordinal").map { |row| row["ordinal"].to_i }
      end
    end

    # Postgres stores the nextval() default as a regclass reference, so the rename keeps it
    it "keeps the sequence behind the ordinal default across the rename" do
      expect(ordinals_after_a_second_write).to eq([1, 2])
    end

    it "never rewrites the frozen held text — the old name stays authentic historical record" do
      held = with_pg(dbname: RENAME_DB) do |db|
        db.exec("SELECT held_text FROM hecks_eras WHERE domain = 'NewName' AND ordinal = 1")[0]["held_text"]
      end

      expect(held).to eq(OLD_SOURCE)
    end

    it "is idempotent across repeated boots", :aggregate_failures do
      expect { check!(NEW_SOURCE) }.not_to raise_error
      expect { check!(NEW_SOURCE) }.not_to raise_error
      expect(count_in("hecks_eras", "NewName")).to eq("1")
    end
  end

  context "with the old domain's bookkeeping tables all in existence" do
    before do
      check!(OLD_SOURCE)
      # as the owner: reattest! lazily creates hecks_attestations, which the rename must own
      with_pg(FencedOwner.url(RENAME_DB)) do |db|
        Hecks::Adapters::PostgresEra::Lineage.new(db, "OldName").reattest!(1) # forces hecks_attestations into existence
      end
      check!(NEW_SOURCE)
    end

    it "renames the domain column across hecks_eras, hecks_era_texts, and hecks_attestations" do
      tables = %w[hecks_eras hecks_era_texts hecks_attestations]

      expect(tables.map { |table| [count_in(table, "OldName"), count_in(table, "NewName")] }).to all(eq(%w[0 1]))
    end
  end

  context "with an app role granted on the old name" do
    def insert_as_app_role(domain, id)
      as_app_role("INSERT INTO #{journal_name(domain)} (era, aggregate, aggregate_id, operation, state) " \
                  "VALUES (1, 'acct', '#{id}', 'save', '{}'::jsonb)")
    end

    before do
      reset_app_role!
      write_old_record
      check!(OLD_SOURCE, role: RENAME_ROLE)
    end

    it "lets the role write before the rename" do
      expect(insert_as_app_role("OldName", "granted-before")).to eq(:allowed)
    end

    it "GRANTs and RLS survive the physical rename without any re-grant" do
      # no role: passed, so grant_role! never runs; surviving access is the rename's doing
      check!(NEW_SOURCE)

      expect(insert_as_app_role("NewName", "granted-after")).to eq(:allowed)
    end
  end

  context "with a rename that also changes the shape" do
    before { write_old_record }

    # An edge that names the aggregate but never backfills the new required `:note`
    # must still hit mint!'s coverage check (ADR 0025), not pass because an edge exists.
    # A value-object-typed backfill default is deliberately not exercised here: it
    # diverges between the SQL transform and the Ruby re-derivation in audit! Layer 2.
    def uncovered_edge
      <<~RUBY
        Hecks.data_translation("NewName", from: #{label_of(OLD_SOURCE).inspect}, to: #{label_of(NEW_SOURCE_CHANGED).inspect}) do
          aggregate("Acct") do
          end
        end
      RUBY
    end

    it "still requires a translation edge — it hits mint!, not a silent pass" do
      expect { check!(NEW_SOURCE_CHANGED) }.to raise_error(
        Hecks::Runtime::WiringError, /cannot boot NewName: the shape changed \(era 2\) and no translation edge covers it/
      )
    end

    it "still hits mint!'s coverage check when an edge exists but covers nothing" do
      expect { check!(NEW_SOURCE_CHANGED, translation_source: uncovered_edge) }.to raise_error(
        Hecks::Runtime::WiringError, /:note is new and required, with no default:/
      )
    end
  end

  it "formerly_known_as pointing at a name with no held history falls through harmlessly" do
    check!(NEW_SOURCE) # OLD_SOURCE was never booted at all — a plain fresh hold

    expect([count_in("hecks_eras", "NewName"), count_in("hecks_eras", "OldName")]).to eq(%w[1 0])
  end

  context "with a stale connection holding the old domain's advisory lock" do
    def advisory_lock_holder
      holder = PG.connect(dbname: RENAME_DB)
      holder.exec("BEGIN")
      holder.exec_params("SELECT pg_advisory_xact_lock(hashtext($1))", ["hecks_eras:OldName"])
      holder
    end

    # Boots the new name while the lock is held, then releases it; answers whether the boot was
    # still waiting while the lock was held, and whether it still was after the release.
    def rename_while_lock_held
      holder = advisory_lock_holder
      renamed = Thread.new { check!(NEW_SOURCE) }
      sleep 0.3
      waiting = renamed.alive?
      holder.exec("COMMIT")
      renamed.join(2)
      [waiting, renamed.alive?]
    ensure
      holder&.close
    end

    it "genuinely blocks the rename, not races past it", :aggregate_failures do
      check!(OLD_SOURCE)
      waiting, still_alive = rename_while_lock_held

      expect(waiting).to be(true) # still waiting on the lock; the rename has not happened
      expect(still_alive).to be(false) # released the instant the lock was — not before
      expect(count_in("hecks_eras", "NewName")).to eq("1")
    end
  end
end
