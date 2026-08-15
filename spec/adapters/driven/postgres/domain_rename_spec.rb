require "hecksagain"
require_relative "../../../support/postgres_probe"

# `formerly_known_as` — a domain's own declared identity can change, and
# this proves the storage layer bridges its real history under the new
# name instead of minting a brand-new lineage from nothing. Runs only
# when a Postgres server is reachable — the shared probe in
# support/postgres_probe.rb, like every other Postgres spec here.
RSpec.describe "domain rename (formerly_known_as) in the Postgres adapter",
               io: true do
  RENAME_DB = "hecksagain_domain_rename_spec".freeze
  RENAME_ROLE = "hecksagain_domain_rename_spec_app".freeze

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

  # Same shape as OLD_SOURCE — only the domain's own identity changed.
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

  # Renamed AND structurally different — a new field with no counterpart
  # in the old shape.
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
  end

  def load_registry(source, translation_source: nil)
    registry = Hecksagain::Runtime::Registry.new
    loading = Hecksagain::Ports::Loading.bootstrap
    file = Tempfile.new(["domain-rename-", ".bluebook"])
    file.write(source)
    file.flush
    Hecksagain.with_registry(registry) do
      loading.load_library
      Kernel.eval(source, TOPLEVEL_BINDING, file.path, 1)
      eval(translation_source) if translation_source
    end
    registry
  ensure
    file&.close!
  end

  def check!(source, translation_source: nil, role: nil)
    registry = load_registry(source, translation_source: translation_source)
    bluebook = registry.bluebooks.values.first
    settings = { database: RENAME_DB }
    settings[:role] = role if role
    Hecksagain::Adapters::Postgres::LineageManager.check!(
      registry: registry, bluebook: bluebook, current_text: source, settings: settings
    )
    registry
  end

  def hash_of(source)
    registry = load_registry(source)
    Hecksagain::Runtime::StorageShape.mint_hash(registry.bluebooks.values.first)
  end

  def label_of(source) = hash_of(source)[0, 6]

  def journal_name(domain) = "hecks_journal_#{Hecksagain::Naming.snake(domain)}"

  def to_regclass(db, relation)
    db.exec_params("SELECT to_regclass($1)", [relation])[0]["to_regclass"]
  end

  def adapter_for(registry, aggregate_name, domain:)
    aggregate = registry.bluebooks.values.first.aggregate(aggregate_name)
    Hecksagain::Adapters::Postgres.new(aggregate: aggregate, settings: { database: RENAME_DB, domain: domain })
  end

  def reset_app_role!
    db = PG.connect(dbname: RENAME_DB)
    begin
      db.exec("DROP OWNED BY #{RENAME_ROLE}")
    rescue PG::Error # rubocop:disable Lint/SuppressedException
    end
    db.close
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP ROLE IF EXISTS #{RENAME_ROLE}")
    admin.exec("CREATE ROLE #{RENAME_ROLE} LOGIN")
    admin.close
    db = PG.connect(dbname: RENAME_DB)
    db.exec("GRANT CONNECT ON DATABASE #{RENAME_DB} TO #{RENAME_ROLE}")
    db.exec("GRANT USAGE ON SCHEMA public TO #{RENAME_ROLE}")
    db.close
  end

  def as_app_role(sql)
    db = PG.connect(dbname: RENAME_DB, user: RENAME_ROLE)
    db.exec(sql)
    :allowed
  rescue PG::Error => error
    error.message.strip
  ensure
    db&.close
  end

  def write_old_record
    registry = check!(OLD_SOURCE)
    adapter = adapter_for(registry, "Acct", domain: "OldName")
    adapter.save(Hecksagain::Runtime::Instance.new(
                   aggregate: registry.bluebooks.values.first.aggregate("Acct"), id: "a1",
                   state: { number: { "value" => "a1" }, balance: { "cents" => 500 } }
                 ))
  end

  it "boots as a quiet reboot — same shape under a new name mints no new era" do
    write_old_record
    registry = check!(NEW_SOURCE)

    expect(registry.resolved_eras["NewName"]).to eq(1)

    db = PG.connect(dbname: RENAME_DB)
    old_rows = db.exec("SELECT ordinal FROM hecks_eras WHERE domain = 'OldName'")
    new_rows = db.exec("SELECT ordinal FROM hecks_eras WHERE domain = 'NewName' ORDER BY ordinal")
    expect(old_rows.ntuples).to eq(0)
    expect(new_rows.ntuples).to eq(1)
    expect(new_rows[0]["ordinal"]).to eq("1")
    db.close

    adapter = adapter_for(registry, "Acct", domain: "NewName")
    expect(adapter.find("a1").balance.to_h).to eq(cents: 500)
  end

  it "physically renames the journal, its sequence, and every partition — the old names are gone" do
    write_old_record
    check!(NEW_SOURCE)

    db = PG.connect(dbname: RENAME_DB)
    expect(to_regclass(db, journal_name("OldName"))).to be_nil
    expect(to_regclass(db, journal_name("NewName"))).not_to be_nil
    expect(to_regclass(db, "#{journal_name('OldName')}_era_1")).to be_nil
    expect(to_regclass(db, "#{journal_name('NewName')}_era_1")).not_to be_nil
    expect(to_regclass(db, "#{journal_name('OldName')}_ordinal")).to be_nil
    expect(to_regclass(db, "#{journal_name('NewName')}_ordinal")).not_to be_nil

    # the renamed sequence's nextval() default survived untouched —
    # Postgres stores it as a regclass reference, not literal text
    db.exec_params(
      "INSERT INTO #{journal_name('NewName')} (era, aggregate, aggregate_id, operation, state) " \
      "VALUES (1, 'acct', 'a2', 'save', '{}'::jsonb)"
    )
    ordinals = db.exec("SELECT ordinal FROM #{journal_name('NewName')} ORDER BY ordinal").map { |r| r["ordinal"].to_i }
    expect(ordinals).to eq([1, 2])
    db.close
  end

  it "renames the domain column across hecks_eras, hecks_era_texts, hecks_approvals, and hecks_attestations" do
    check!(OLD_SOURCE)
    db = PG.connect(dbname: RENAME_DB)
    lineage = Hecksagain::Adapters::Postgres::Lineage.new(db, "OldName")
    lineage.reattest!(1) # forces hecks_attestations into existence under the OLD name
    db.close

    check!(NEW_SOURCE)

    db = PG.connect(dbname: RENAME_DB)
    expect(db.exec("SELECT count(*) FROM hecks_eras WHERE domain = 'OldName'")[0]["count"]).to eq("0")
    expect(db.exec("SELECT count(*) FROM hecks_era_texts WHERE domain = 'OldName'")[0]["count"]).to eq("0")
    expect(db.exec("SELECT count(*) FROM hecks_attestations WHERE domain = 'OldName'")[0]["count"]).to eq("0")
    expect(db.exec("SELECT count(*) FROM hecks_eras WHERE domain = 'NewName'")[0]["count"]).to eq("1")
    expect(db.exec("SELECT count(*) FROM hecks_era_texts WHERE domain = 'NewName'")[0]["count"]).to eq("1")
    expect(db.exec("SELECT count(*) FROM hecks_attestations WHERE domain = 'NewName'")[0]["count"]).to eq("1")
    db.close
  end

  it "never rewrites the frozen held text — the old name stays authentic historical record" do
    write_old_record
    check!(NEW_SOURCE)

    db = PG.connect(dbname: RENAME_DB)
    held = db.exec("SELECT held_text FROM hecks_eras WHERE domain = 'NewName' AND ordinal = 1")[0]["held_text"]
    db.close
    expect(held).to eq(OLD_SOURCE)
  end

  it "GRANTs and RLS survive the physical rename without any re-grant" do
    reset_app_role!
    write_old_record
    check!(OLD_SOURCE, role: RENAME_ROLE)
    expect(
      as_app_role("INSERT INTO #{journal_name('OldName')} (era, aggregate, aggregate_id, operation, state) " \
                  "VALUES (1, 'acct', 'granted-before', 'save', '{}'::jsonb)")
    ).to eq(:allowed)

    # no role: passed here — grant_role! never runs on this boot, so
    # anything the app role can still do afterward is the rename's own
    # doing, not a fresh grant
    check!(NEW_SOURCE)

    expect(
      as_app_role("INSERT INTO #{journal_name('NewName')} (era, aggregate, aggregate_id, operation, state) " \
                  "VALUES (1, 'acct', 'granted-after', 'save', '{}'::jsonb)")
    ).to eq(:allowed)
  end

  it "a rename with a real structural change still requires a translation edge — it hits mint!, not a silent pass" do
    write_old_record
    old_label = label_of(OLD_SOURCE)

    expect { check!(NEW_SOURCE_CHANGED) }.to raise_error(
      Hecksagain::Runtime::WiringError, /cannot boot NewName: the shape changed \(era 2\) and no translation edge covers it/
    )

    new_label = label_of(NEW_SOURCE_CHANGED)
    edge = <<~RUBY
      Hecks.data_translation("NewName", from: #{old_label.inspect}, to: #{new_label.inspect}) do
        aggregate("Acct") do
        end
      end
    RUBY

    registry = check!(NEW_SOURCE_CHANGED, translation_source: edge)
    expect(registry.resolved_eras["NewName"]).to eq(2)

    adapter = adapter_for(registry, "Acct", domain: "NewName")
    found = adapter.find("a1")
    expect(found.balance.to_h).to eq(cents: 500)
    expect(found.key?(:note)).to be(false)
  end

  it "is idempotent across repeated boots" do
    write_old_record
    check!(NEW_SOURCE)
    expect { check!(NEW_SOURCE) }.not_to raise_error
    expect { check!(NEW_SOURCE) }.not_to raise_error

    db = PG.connect(dbname: RENAME_DB)
    expect(db.exec("SELECT count(*) FROM hecks_eras WHERE domain = 'NewName'")[0]["count"]).to eq("1")
    db.close
  end

  it "formerly_known_as pointing at a name with no held history falls through harmlessly" do
    check!(NEW_SOURCE) # OLD_SOURCE was never booted at all — a plain fresh hold

    db = PG.connect(dbname: RENAME_DB)
    expect(db.exec("SELECT count(*) FROM hecks_eras WHERE domain = 'NewName'")[0]["count"]).to eq("1")
    expect(db.exec("SELECT count(*) FROM hecks_eras WHERE domain = 'OldName'")[0]["count"]).to eq("0")
    db.close
  end

  it "a stale connection still holding the old domain's advisory lock genuinely blocks the rename, not races past it" do
    check!(OLD_SOURCE)

    holder = PG.connect(dbname: RENAME_DB)
    holder.exec("BEGIN")
    holder.exec_params("SELECT pg_advisory_xact_lock(hashtext($1))", ["hecks_eras:OldName"])

    renamed = Thread.new { check!(NEW_SOURCE) }
    sleep 0.3
    expect(renamed).to be_alive # still waiting on the lock ; the rename has not happened

    holder.exec("COMMIT")
    renamed.join(2)
    expect(renamed).not_to be_alive # released the instant the lock was — not before

    db = PG.connect(dbname: RENAME_DB)
    expect(db.exec("SELECT count(*) FROM hecks_eras WHERE domain = 'NewName'")[0]["count"]).to eq("1")
    db.close
    holder.close
  end
end
