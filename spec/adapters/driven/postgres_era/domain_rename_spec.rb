require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../../support/postgres_probe"
require_relative "../../../support/scratch_postgres"
require_relative "../../../support/fenced_owner"
require_relative "../../../support/era_registry_loading"
require_relative "../../../support/era_app_role"
require_relative "../../../support/first_era_hold"
require_relative "../../../support/mint_request_support"
require_relative "../../../support/thread_parking"

# `formerly_known_as`: a rename moves a held domain's history to its new name, through the rename
# entry point (`Lineage#rename_domain!`, which `Era.RenameDomain` applies). A boot under the new
# name until the rename refuses by name and writes nothing.
# Runs only when a Postgres server is reachable (support/postgres_probe.rb).
RSpec.describe "domain rename (formerly_known_as) in the PostgresEra adapter", :io do
  include EraRegistryLoading
  include FirstEraHold
  include EraAppRole
  include MintRequestSupport

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

  scratch_postgres RENAME_DB, fenced: true

  def app_role_database = RENAME_DB
  def app_role_name = RENAME_ROLE

  # Checks the source as a boot, which carries no mint request. `mint: true` runs the mint entry
  # point instead: the copy's world allows minting and the request is a confirmed would_mint
  # rehearsal at the watermark the database holds.
  def check!(source, translation_source: nil, role: nil, mint: false)
    registry = load_registry(source, translation_source: translation_source)
    bluebook = registry.bluebooks.values.first
    settings = { database: FencedOwner.url(RENAME_DB) }
    settings[:role] = role if role
    # The rehearsal reads the watermark of the journal the database holds under the domain's name.
    settings = with_mint_request(settings.merge(mint_eras: true), domain: bluebook.name) if mint
    Hecks::Adapters::PostgresEra::LineageManager.check!(
      registry: registry, bluebook: bluebook, current_text: source, settings: settings
    )
    registry
  end

  # Moves the history held under the source's former name to its name, as `Era.RenameDomain` applies
  # it, on the owner's connection. Answers the count of eras moved.
  def rename!(source)
    bluebook = load_registry(source).bluebooks.values.first
    with_pg(FencedOwner.url(RENAME_DB)) do |db|
      Hecks::Adapters::PostgresEra::Lineage.new(db, bluebook.name, formerly_known_as: bluebook.formerly_known_as)
                                           .rename_domain!(storage_names: bluebook.aggregates.map(&:storage_name))
    end
  end

  # The rename, then a boot under the new name.
  def rename_and_boot!(source, **options)
    rename!(source)
    check!(source, **options)
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

  # Holds era 1 under the old name, as `hold_first` does, then boots it and writes a record.
  def write_old_record
    hold_first_era!(url: FencedOwner.url(RENAME_DB), domain: "OldName", source: OLD_SOURCE)
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

  context "with the old record written, and a boot under the new name ahead of the rename" do
    before { write_old_record }

    it "refuses by name and points at the rename, starting no fresh history", :aggregate_failures do
      expect { check!(NEW_SOURCE) }.to raise_error(
        Hecks::Runtime::WiringError, /NewName.*held under the former name OldName.*era\.rename_domain first/
      )
      expect(presence(journal_name("OldName"), journal_name("NewName"))).to eq([true, false])
    end

    it "refuses a mint request the same way, before it provisions anything", :aggregate_failures do
      expect { check!(NEW_SOURCE, mint: true) }.to raise_error(Hecks::Runtime::WiringError, /era\.rename_domain first/)
      expect(presence(journal_name("NewName"))).to eq([false])
      expect(count_in("hecks_eras", "OldName")).to eq("1")
    end

    it "moves the one era, and a second rename finds nothing to move", :aggregate_failures do
      expect([rename!(NEW_SOURCE), rename!(NEW_SOURCE)]).to eq([1, 0])
    end
  end

  context "with the old record written, and the same shape booted under the new name" do
    before do
      write_old_record
      @registry = rename_and_boot!(NEW_SOURCE)
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
      hold_first_era!(url: FencedOwner.url(RENAME_DB), domain: "OldName", source: OLD_SOURCE)
      check!(OLD_SOURCE)
      # as the owner: reattest! lazily creates hecks_attestations, which the rename must own
      with_pg(FencedOwner.url(RENAME_DB)) do |db|
        # Forces hecks_attestations into existence.
        Hecks::Adapters::PostgresEra::Lineage.new(db, "OldName").reattest!(1)
      end
      rename_and_boot!(NEW_SOURCE)
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

    # The app role is granted when the first era is provisioned, not by a boot.
    before do
      reset_app_role!
      hold_first_era!(url: FencedOwner.url(RENAME_DB), domain: "OldName", source: OLD_SOURCE, role: RENAME_ROLE)
      write_old_record
      check!(OLD_SOURCE, role: RENAME_ROLE)
    end

    it "lets the role write before the rename" do
      expect(insert_as_app_role("OldName", "granted-before")).to eq(:allowed)
    end

    it "GRANTs and RLS survive the physical rename without any re-grant" do
      # no role: passed, so grant_role! never runs; surviving access is the rename's doing
      rename_and_boot!(NEW_SOURCE)

      expect(insert_as_app_role("NewName", "granted-after")).to eq(:allowed)
    end
  end

  context "with a rename that also changes the shape" do
    before do
      write_old_record
      rename!(NEW_SOURCE_CHANGED)
    end

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

    # A boot carries no mint request, so the changed shape reads the held era and appends nothing.
    # The move is breaking, so a boot over it needs an edge present; the mint entry point is what
    # judges that edge's coverage.
    it "boot reads a changed shape without minting", :aggregate_failures do
      registry = check!(NEW_SOURCE_CHANGED, translation_source: uncovered_edge)
      expect(count_in("hecks_eras", "NewName")).to eq("1")
      expect(registry.resolved_eras["NewName"]).to eq(1)
      expect(adapter_for(registry, "Acct", domain: "NewName").find("a1").balance.to_h).to eq(cents: 500)
    end

    it "the mint entry point refuses a changed shape with no translation edge by name" do
      expect { check!(NEW_SOURCE_CHANGED, mint: true) }.to raise_error(
        Hecks::Runtime::WiringError, /cannot boot NewName: the shape changed \(era 2\) and no translation edge covers it/
      )
    end

    it "the mint entry point refuses an uncovered edge by name" do
      expect { check!(NEW_SOURCE_CHANGED, translation_source: uncovered_edge, mint: true) }.to raise_error(
        Hecks::Runtime::WiringError, /:note is new and required, with no default:/
      )
    end
  end

  it "formerly_known_as pointing at a name with no held history falls through harmlessly" do
    # OLD_SOURCE was never held at all: a plain fresh hold under the new name
    hold_first_era!(url: FencedOwner.url(RENAME_DB), domain: "NewName", source: NEW_SOURCE)
    rename!(NEW_SOURCE)
    check!(NEW_SOURCE)

    expect([count_in("hecks_eras", "NewName"), count_in("hecks_eras", "OldName")]).to eq(%w[1 0])
  end

  context "with a stale connection holding the old domain's advisory lock" do
    def advisory_lock_holder
      holder = PG.connect(dbname: RENAME_DB)
      holder.exec("BEGIN")
      holder.exec_params("SELECT pg_advisory_xact_lock(hashtext($1))", ["hecks_eras:OldName"])
      holder
    end

    # Renames while the lock is held, then releases it; answers whether the rename was still
    # waiting while the lock was held, and whether it still was after the release.
    def rename_while_lock_held
      holder = advisory_lock_holder
      renamed = Thread.new { rename!(NEW_SOURCE) }
      ThreadParking.wait_until_parked(renamed)
      waiting = renamed.alive?
      holder.exec("COMMIT")
      renamed.join(2)
      [waiting, renamed.alive?]
    ensure
      holder&.close
    end

    it "genuinely blocks the rename, not races past it", :aggregate_failures do
      hold_first_era!(url: FencedOwner.url(RENAME_DB), domain: "OldName", source: OLD_SOURCE)
      waiting, still_alive = rename_while_lock_held

      expect(waiting).to be(true) # still waiting on the lock; the rename has not happened
      expect(still_alive).to be(false) # released the instant the lock was — not before
      expect(count_in("hecks_eras", "NewName")).to eq("1")
    end
  end
end
