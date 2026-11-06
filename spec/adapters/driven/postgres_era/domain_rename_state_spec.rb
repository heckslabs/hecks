require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../../support/postgres_probe"
require_relative "../../../support/scratch_postgres"
require_relative "../../../support/fenced_owner"
require_relative "../../../support/era_registry_loading"
require_relative "../../../support/first_era_hold"
require_relative "../../../support/thread_parking"

# A domain rename moves every table keyed by the old name, the heads of aggregates the bluebook no
# longer lists, the field caches and the backfill cursors, and it reads the eras only after the
# locks are granted.
RSpec.describe "PostgresRevision domain rename state", :io do
  include EraRegistryLoading
  include FirstEraHold

  STATE_DB = "hecks_domain_rename_state_spec".freeze

  STATE_BODY = <<~BODY.freeze
    aggregate "Acct" do
      identified_by :number
      attribute :number, Num
      attribute :status, Num

      value_object "Num" do
        attribute :value, String
      end

      query "Open" do
        where(status: "open")
      end
    end
  BODY

  # The aggregate Gone is in the old bluebook only.
  OLD_STATE_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "OldState" do
      #{STATE_BODY.gsub("\n", "\n  ").strip}

      aggregate "Gone" do
        identified_by :tag
        attribute :tag, Tag

        value_object "Tag" do
          attribute :value, String
        end
      end
    end
  BLUEBOOK

  NEW_STATE_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "NewState" do
      formerly_known_as "OldState"

      #{STATE_BODY.gsub("\n", "\n  ").strip}
    end
  BLUEBOOK

  scratch_postgres STATE_DB, fenced: true

  def connect = PG.connect(FencedOwner.url(STATE_DB))

  def rename_with(db)
    Hecks::Adapters::PostgresRevision::Lineage.new(db, "NewState", formerly_known_as: "OldState")
                                              .rename_domain!(storage_names: ["acct"], cache_fields: { "acct" => ["status"] })
  end

  # Holds the old domain's first era and provisions the cache and progress rows of its Acct.
  def hold_old!
    hold_first_era!(url: FencedOwner.url(STATE_DB), domain: "OldState", source: OLD_STATE_SOURCE)
    seed_other_state!
  end

  def seed_other_state!
    db = connect
    db.exec(Hecks::Adapters::PostgresRevision::Lineage::LedgerReset::ARCHIVES_SQL)
    db.exec("INSERT INTO hecks_ledger_archives (domain, aggregate, archive, row_count) " \
            "VALUES ('OldState', 'gone', 'old_state_gone_archived_20261001000000', 0)")
    db.exec("CREATE TABLE old_state_gone_archived_20261001000000 (x int)")
    db.exec(Hecks::Adapters::PostgresRevision::Sagas::CREATE_SAGAS_SQL)
    db.exec("INSERT INTO hecks_saga_instances (domain, process_manager, correlation, state, memory) " \
            "VALUES ('OldState', 'Pm', 'c1', 'open', '{}')")
    db.close
  end

  def old_lineage(db) = Hecks::Adapters::PostgresRevision::Lineage.new(db, "OldState")

  def relations_like(pattern)
    db = connect
    db.exec_params("SELECT relname FROM pg_class WHERE relname LIKE $1 AND pg_table_is_visible(oid)", [pattern])
      .map { |row| row["relname"] }
  ensure
    db&.close
  end

  def domain_tables(db)
    db.exec("SELECT table_name FROM information_schema.columns WHERE column_name = 'domain' " \
            "AND table_schema = 'public'").map { |row| row["table_name"] }
  end

  def rows_keyed_by_old_name
    db = connect
    domain_tables(db).sum { |table| db.exec("SELECT count(*) FROM #{table} WHERE domain = 'OldState'")[0]["count"].to_i }
  ensure
    db&.close
  end

  def orphan_cursors
    db = connect
    return [] unless db.exec("SELECT to_regclass('hecks_backfill_progress') AS t")[0]["t"]

    targets = db.exec("SELECT target FROM hecks_backfill_progress").map { |row| row["target"] }
    targets.reject { |target| db.exec_params("SELECT to_regclass($1) AS t", [%("#{target}")])[0]["t"] }
  ensure
    db&.close
  end

  # A cache and a snapshot cursor, as a boot of the old domain leaves them.
  def provision_old_cache!
    db = connect
    lineage = old_lineage(db)
    lineage.ensure_field_cache!("acct", 1, "status", "state->>'status'")
    db.close
  end

  context "with the rename done" do
    before do
      hold_old!
      provision_old_cache!
      db = connect
      @moved = rename_with(db)
      db.close
    end

    it "leaves no relation under the old name, removed aggregates included" do
      expect(relations_like("old\\_state%") + relations_like("hecks\\_journal\\_old\\_state%")).to be_empty
    end

    it "leaves no row keyed by the old name in any domain table" do
      expect(rows_keyed_by_old_name).to eq(0)
    end

    it "moves the head of an aggregate the bluebook no longer lists" do
      expect(relations_like("new\\_state\\_gone\\_head")).not_to be_empty
    end

    it "leaves no backfill cursor naming a relation that is gone" do
      expect(orphan_cursors).to be_empty
    end

    it "moves the field cache the new name hashes" do
      db = connect
      cache = Hecks::Adapters::PostgresRevision::Lineage.new(db, "NewState").field_cache("acct", 1, "status")
      expect(relations_like(cache)).to eq([cache])
    ensure
      db&.close
    end

    it "moves the archive list and its table" do
      db = connect
      expect(db.exec("SELECT archive FROM hecks_ledger_archives").map { |row| row["archive"] })
        .to eq(["new_state_gone_archived_20261001000000"])
    ensure
      db&.close
    end

    it "is a no-op when run again", :aggregate_failures do
      db = connect
      expect(rename_with(db)).to eq(0)
      expect(@moved).to eq(1)
    ensure
      db&.close
    end
  end

  context "with a mint landing before the rename gets its locks" do
    # Holds the old domain's era lock as a mint would, and commits era 2 and its partition while
    # the rename waits.
    def mint_while_rename_waits
      minter = connect
      minter.exec("BEGIN")
      minter.exec("SELECT pg_advisory_xact_lock(hashtext('hecks_eras:OldState'))")
      renamed = Thread.new { rename_in_thread }
      ThreadParking.wait_until_parked(renamed)
      land_era_two!(minter)
      minter.exec("COMMIT")
      renamed.join(5)
      [renamed, minter]
    end

    def rename_in_thread
      db = connect
      rename_with(db)
    ensure
      db&.close
    end

    def land_era_two!(minter)
      minter.exec("INSERT INTO hecks_eras (domain, ordinal, held_text, label) VALUES ('OldState', 2, 'x', 'abcdef')")
      old_lineage(minter).ensure_partition!(2)
    end

    before { hold_old! }

    it "renames the partition the mint wrote while the rename waited", :aggregate_failures do
      renamed, minter = mint_while_rename_waits
      expect(renamed.value).to eq(2)
      expect(relations_like("hecks\\_journal\\_%\\_era\\_2")).to eq(["hecks_journal_new_state_era_2"])
    ensure
      minter&.close
    end
  end
end
