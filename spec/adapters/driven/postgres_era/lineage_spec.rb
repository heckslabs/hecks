require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../../support/postgres_probe"
require_relative "../../../support/era_registry_loading"
require_relative "../../../support/era_app_role"

# Lineage in the PostgresEra adapter: partitioned journal, era rows, the one-transaction mint,
# and the head compiled as a chain of edges. Needs a reachable Postgres (see postgres_probe.rb).
RSpec.describe "lineage in the PostgresEra adapter", :io do
  include EraRegistryLoading
  include EraAppRole

  LINEAGE_DB = "hecks_lineage_spec".freeze

  # Table owner for the whole file: a non-superuser role, since a superuser bypasses RLS and
  # the "owner is fenced too" assertions would pass for the wrong reason.
  LINEAGE_OWNER = "hecks_lineage_owner".freeze

  def owner_url = "postgres://#{LINEAGE_OWNER}@localhost/#{LINEAGE_DB}"

  V1_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "Ledger" do
      aggregate "Acct" do
        identified_by :kind

        attribute :cost, Money
        attribute :kind, Kind
        attribute :legacy_note, Note

        value_object "Money" do
          attribute :cents, Integer
          attribute :currency, String
        end

        value_object "Kind" do
          attribute :label, String
        end

        value_object "Note" do
          attribute :text, String
        end
      end
    end
  BLUEBOOK

  V2_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "Ledger" do
      aggregate "Account" do
        identified_by :kind

        attribute :amount, Money
        attribute :kind, Kind
        attribute :denomination, Denomination

        value_object "Money" do
          attribute :cents, Integer
        end

        value_object "Kind" do
          attribute :label, String
        end

        value_object "Denomination" do
          attribute :code, String
        end
      end
    end
  BLUEBOOK

  # Era 3 is the first mint that can read era 2's matview instead of raw history.
  V3_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "Ledger" do
      aggregate "Account" do
        identified_by :kind

        attribute :balance, Money
        attribute :kind, Kind
        attribute :denomination, Denomination

        value_object "Money" do
          attribute :cents, Integer
        end

        value_object "Kind" do
          attribute :label, String
        end

        value_object "Denomination" do
          attribute :code, String
        end
      end
    end
  BLUEBOOK

  def edge_source_v3(from:, to:)
    <<~RUBY
      Hecks.data_translation("Ledger", from: #{from.inspect}, to: #{to.inspect}) do
        aggregate("Account") do
          rename :amount, to: :balance
        end
      end
    RUBY
  end

  # V3 with identity moved from `kind` to `ref`: the bare-rename V3 edge never changes identity,
  # so only this one exercises layered_chain_sql's id_column case.
  V3_REKEYED_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "Ledger" do
      aggregate "Account" do
        identified_by :ref

        attribute :amount, Money
        attribute :kind, Kind
        attribute :denomination, Denomination
        attribute :ref, Ref

        value_object "Money" do
          attribute :cents, Integer
        end

        value_object "Kind" do
          attribute :label, String
        end

        value_object "Denomination" do
          attribute :code, String
        end

        value_object "Ref" do
          attribute :value, String
        end
      end
    end
  BLUEBOOK

  def edge_source_v3_rekey(from:, to:)
    <<~RUBY
      Hecks.data_translation("Ledger", from: #{from.inspect}, to: #{to.inspect}) do
        aggregate("Account") do
          rekey sql: "'ref-' || ((__s -> 'kind') ->> 'label')"
          backfill :ref, default: "unknown"
        end
      end
    RUBY
  end

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{LINEAGE_DB} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{LINEAGE_DB}")
    admin.exec("DROP ROLE IF EXISTS #{LINEAGE_OWNER}")
    # Plain LOGIN role: superuser or BYPASSRLS would make force RLS a no-op.
    admin.exec("CREATE ROLE #{LINEAGE_OWNER} LOGIN")
    admin.close
    grant = PG.connect(dbname: LINEAGE_DB)
    grant.exec("GRANT CONNECT ON DATABASE #{LINEAGE_DB} TO #{LINEAGE_OWNER}")
    grant.close
    # The schema grant is re-issued in `before do`, which recreates `public` each example.
  end

  after(:all) do
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{LINEAGE_DB} WITH (FORCE)")
    admin.close
  end

  before do
    scrub = PG.connect(dbname: LINEAGE_DB)
    scrub.exec("DROP SCHEMA public CASCADE")
    scrub.exec("CREATE SCHEMA public")
    scrub.exec("GRANT USAGE, CREATE ON SCHEMA public TO #{LINEAGE_OWNER}")
    scrub.close
  end

  def app_role_database = LINEAGE_DB
  def app_role_name = LINEAGE_ROLE

  def check!(source, translation_source: nil, role: nil)
    registry = load_registry(source, translation_source: translation_source)
    bluebook = registry.bluebooks.values.first
    settings = { database: owner_url }
    settings[:role] = role if role
    Hecks::Adapters::PostgresEra::LineageManager.check!(
      registry: registry, bluebook: bluebook, current_text: source, settings: settings
    )
    registry
  end

  # A deployment's app role: a non-owner, the only kind of connection the era fence acts on.
  LINEAGE_ROLE = "hecks_lineage_spec_app".freeze

  def hash_of(source)
    registry = load_registry(source)
    Hecks::Runtime::StorageShape.mint_hash(registry.bluebooks.values.first)
  end

  def label_of(source) = hash_of(source)[0, 6]

  def adapter_for(registry, aggregate_name)
    aggregate = registry.bluebooks.values.first.aggregate(aggregate_name)
    Hecks::Adapters::PostgresEra.new(aggregate: aggregate, settings: { database: owner_url, domain: "Ledger" })
  end

  def v1_record_state
    {
      cost:        { "cents" => 100, "currency" => "USD" },
      kind:        { "label" => "biz" },
      legacy_note: { "text" => "keep?" }
    }
  end

  def write_v1_record(state = nil)
    registry = check!(V1_SOURCE)
    adapter = adapter_for(registry, "Acct")
    aggregate = registry.bluebooks.values.first.aggregate("Acct")
    adapter.save(Hecks::Runtime::Instance.new(aggregate: aggregate, id: "a1", state: state || v1_record_state))
  end

  def edge_source(from:, to:)
    <<~RUBY
      Hecks.data_translation("Ledger", from: #{from.inspect}, to: #{to.inspect}) do
        aggregate("Account", was: "Acct") do
          rename :cost, to: :amount
          move "amount.currency", to: "denomination.code"
          convert "kind.label", to: "kind.label", values: { "biz" => "business", "pers" => "personal" }
          drop :legacy_note
        end
      end
    RUBY
  end

  # Checks an already loaded registry against the database as the owner.
  def check_loaded!(registry, text)
    Hecks::Adapters::PostgresEra::LineageManager.check!(
      registry: registry, bluebook: registry.bluebooks.values.first, current_text: text, settings: { database: owner_url }
    )
  end

  def v1_to_v2_edge = edge_source(from: label_of(V1_SOURCE), to: label_of(V2_SOURCE))

  # Mints era 2 through the edge from era 1.
  def mint_v2!(**options) = check!(V2_SOURCE, translation_source: v1_to_v2_edge, **options)

  def with_db(**, &) = with_pg(dbname: LINEAGE_DB, **, &)

  def account_instance(registry, id, state)
    Hecks::Runtime::Instance.new(aggregate: registry.bluebooks.values.first.aggregate("Account"), id: id, state: state)
  end

  # What `hecks_journal_ledger` holds for `era`, as `INSERT ... VALUES` text for a plain write.
  def journal_insert(era, id, aggregate: "account")
    "INSERT INTO hecks_journal_ledger (era, aggregate, aggregate_id, operation, state) " \
      "VALUES (#{era}, '#{aggregate}', '#{id}', 'save', '{}'::jsonb)"
  end

  def count_of(table, where) = with_db { |db| db.exec("SELECT count(*) FROM #{table} WHERE #{where}")[0]["count"] }

  # --- first boot, held text, and the archive -------------------------------------------------

  context "with era 1 held by a first boot" do
    before { check!(V1_SOURCE) }

    it "holds era 1 as a row" do
      rows = with_db { |db| db.exec("SELECT ordinal, hash, held_text FROM hecks_eras WHERE domain = 'Ledger'").to_a }

      expect(rows).to eq([{ "ordinal" => "1", "hash" => nil, "held_text" => V1_SOURCE }])
    end

    it "boots the same shape quietly" do
      expect { check!(V1_SOURCE) }.not_to raise_error
    end
  end

  GENERIC_EDIT_WORDING = "cannot boot Ledger: the held text of era 1 was edited after it was frozen — " \
                         "held era texts are storage facts; restore the original text, or reset the data".freeze

  # Every edit reaches the same generic wording: telling cosmetic from shape edits would need
  # boot to re-parse held era text, so EraTamper.refusal does not.
  context "with the held text of era 1 edited" do
    before { check!(V1_SOURCE) }

    def edit_held_text(text)
      with_db { |db| db.exec_params("UPDATE hecks_eras SET held_text = $1 WHERE domain = 'Ledger' AND ordinal = 1", [text]) }
    end

    it "refuses an edit toward another shape's text — with the archive as recovery" do
      edit_held_text(V2_SOURCE)

      expect { check!(V1_SOURCE) }.to raise_error(Hecks::Runtime::WiringError, GENERIC_EDIT_WORDING)
    end

    it "refuses a comment added by hand" do
      edit_held_text("# a typo fixed\n#{V1_SOURCE}")

      expect { check!(V1_SOURCE) }.to raise_error(Hecks::Runtime::WiringError, GENERIC_EDIT_WORDING)
    end

    # unparseable edit — a misspelled DSL method mid-`Kernel.eval`
    it "refuses a text that no longer parses" do
      edit_held_text(V1_SOURCE.sub("attribute :cost, Money", "atribute :cost, Money"))

      expect { check!(V1_SOURCE) }.to raise_error(Hecks::Runtime::WiringError, GENERIC_EDIT_WORDING)
    end

    it "boots again once the archive's text is put back", :aggregate_failures do
      edit_held_text(V2_SOURCE)
      archived = with_db { |db| db.exec("SELECT held_text FROM hecks_era_texts WHERE domain = 'Ledger' AND ordinal = 1").to_a }
      edit_held_text(archived.first["held_text"])

      expect(archived.map { |row| row["held_text"] }).to eq([V1_SOURCE])
      expect { check!(V1_SOURCE) }.not_to raise_error
    end
  end

  context "with the held text of era 1 edited, then re-attested" do
    before do
      check!(V1_SOURCE)
      @old_digest = with_db do |db|
        db.exec("SELECT held_digest FROM hecks_eras WHERE domain = 'Ledger' AND ordinal = 1")[0]["held_digest"]
      end
      with_db { |db| db.exec_params("UPDATE hecks_eras SET held_text = $1 WHERE ordinal = 1", [V2_SOURCE]) }
    end

    def reattest_era_one! = with_db { |db| Hecks::Adapters::PostgresEra::Lineage.new(db, "Ledger").reattest!(1) }

    def attestation = with_db { |db| db.exec("SELECT * FROM hecks_attestations WHERE domain = 'Ledger'")[0] }

    it "refuses to boot over the edit, until it is attested" do
      expect { check!(V1_SOURCE) }.to raise_error(Hecks::Runtime::WiringError, /edited after it was frozen/)
    end

    it "re-freezes the edited text's digest" do
      expect(reattest_era_one!).to eq(Digest::SHA256.hexdigest(V2_SOURCE))
    end

    it "puts the attestation on the record", :aggregate_failures do
      fresh = reattest_era_one!

      expect(attestation).to include("old_digest" => @old_digest, "new_digest" => fresh)
      expect(attestation["attested_at"]).not_to be_nil
    end

    it "boots the edited text once it is attested" do
      reattest_era_one!

      expect { check!(V2_SOURCE) }.not_to raise_error
    end
  end

  NO_EDGE_REFUSAL = "cannot boot Ledger: the shape changed (era 2) and no translation edge covers it — " \
                    "run hecks scaffold_translation to write the edge, check it with hecks audit_translation, " \
                    "then boot again".freeze

  UNEXPLAINED_LEGACY_NOTE = /
    cannot\ boot\ Ledger::Account:\ its\ shape\ changed\ and\ :legacy_note\ is\ not\ explained\ by\ any
    \ rename,\ move,\ convert,\ retype,\ or\ drop
  /x

  context "with era 1 held and a drifted shape" do
    before { check!(V1_SOURCE) }

    it "refuses drift with no edge, naming both authoring tools" do
      expect { check!(V2_SOURCE) }.to raise_error(Hecks::Runtime::WiringError, NO_EDGE_REFUSAL)
    end

    it "refuses a stale edge whose target hash no longer matches the current shape" do
      stale = edge_source(from: label_of(V1_SOURCE), to: "000000")

      expect { check!(V2_SOURCE, translation_source: stale) }.to raise_error(
        Hecks::Runtime::WiringError, /the edge is stale; re-run hecks scaffold_translation/
      )
    end

    it "refuses a mechanical fork — two edges leaving one source shape" do
      from = label_of(V1_SOURCE)
      forked = edge_source(from: from, to: label_of(V2_SOURCE)) + edge_source(from: from, to: "111111")

      expect { check!(V2_SOURCE, translation_source: forked) }.to raise_error(
        Hecks::Runtime::WiringError, /eras fork mechanically; keep one edge per source shape/
      )
    end

    def partial_edge
      <<~RUBY
        Hecks.data_translation("Ledger", from: #{label_of(V1_SOURCE).inspect}, to: #{label_of(V2_SOURCE).inspect}) do
          aggregate("Account", was: "Acct") do
            rename :cost, to: :amount
            move "amount.currency", to: "denomination.code"
            convert "kind.label", to: "kind.label", values: { "biz" => "business" }
          end
        end
      RUBY
    end

    it "refuses an edge that does not cover the whole diff, in EraGuard's own words" do
      expect { check!(V2_SOURCE, translation_source: partial_edge) }
        .to raise_error(Hecks::Runtime::WiringError, UNEXPLAINED_LEGACY_NOTE)
    end
  end

  # One mint checked from every angle (eras table, era-1 journal row, head, new partition).
  context "with era 2 minted in one transaction through the edge" do
    before do
      write_v1_record
      @registry = mint_v2!
    end

    def era_rows
      with_db do |db|
        db.exec("SELECT ordinal, hash, label, watermark FROM hecks_eras WHERE domain = 'Ledger' ORDER BY ordinal").to_a
      end
    end

    def journal_partitions
      with_db do |db|
        rows = db.exec("SELECT era, count(*) FROM hecks_journal_ledger GROUP BY era ORDER BY era")
        rows.map { |row| [row["era"], row["count"]] }
      end
    end

    it "mints era 2 in one transaction — the eras table holds both labels" do
      expect(era_rows.map { |row| row["label"] }).to eq([label_of(V1_SOURCE), label_of(V2_SOURCE)])
    end

    it "records era 2's hash and its watermark" do
      expect(era_rows[1].values_at("hash", "watermark")).to eq([hash_of(V2_SOURCE), "1"])
    end

    it "leaves the era-1 journal row as it was — never rewritten" do
      rows = with_db { |db| db.exec("SELECT era, aggregate, state FROM hecks_journal_ledger ORDER BY ordinal").to_a }

      expect(rows.map { |row| [row["era"], row["aggregate"], JSON.parse(row["state"])["cost"]] })
        .to eq([["1", "acct", { "cents" => 100, "currency" => "USD" }]])
    end

    it "derives the head through the edge — the old entry translated at inclusion" do
      found = adapter_for(@registry, "Account").find("a1")

      expect([found.amount.to_h, found.denomination.to_h, found.kind.to_h, found.key?(:legacy_note)])
        .to eq([{ cents: 100 }, { code: "USD" }, { label: "business" }, false])
    end

    it "writes a new save to era 2's partition", :aggregate_failures do
      adapter = adapter_for(@registry, "Account")
      adapter.save(account_instance(@registry, "a1", amount: { "cents" => 250 }, kind: { "label" => "business" },
                                                     denomination: { "code" => "EUR" }))

      expect(adapter.find("a1").amount.to_h).to eq(cents: 250)
      expect(journal_partitions).to eq([["1", "1"], ["2", "1"]])
    end
  end

  # A delete writes a tombstone row in the current era's snapshot: a bare DELETE would leave
  # nothing to outrank the ancestor's save row in the head view's DISTINCT ON union.
  context "with an era-migrated record" do
    before do
      write_v1_record
      @registry = mint_v2!
    end

    it "holds the migrated record before any delete" do
      expect(adapter_for(@registry, "Account").find("a1")).not_to be_nil
    end
  end

  context "with an era-migrated record deleted" do
    before do
      write_v1_record
      @registry = mint_v2!
      @adapter = adapter_for(@registry, "Account")
      @adapter.delete("a1")
    end

    it "no longer finds it" do
      expect(@adapter.find("a1")).to be_nil
    end

    it "no longer lists or counts it", :aggregate_failures do
      expect(@adapter.all.map(&:id)).not_to include("a1")
      expect(@adapter.count).to eq(0)
    end

    # a fresh boot's ensure_head_snapshot! backfill must not un-delete it either
    it "stays deleted for a fresh boot's own adapter" do
      expect(adapter_for(@registry, "Account").find("a1")).to be_nil
    end

    it "leaves the head view without it" do
      expect(count_of("ledger_account_head", "id = 'a1'")).to eq("0")
    end

    # the tombstone is a real row that outranks the ancestor's save row
    it "writes a tombstone row in the current era's snapshot" do
      tombstone = with_db { |db| db.exec("SELECT operation, state FROM ledger_account_head_snapshot_2 WHERE id = 'a1'").to_a }

      expect(tombstone).to eq([{ "operation" => "delete", "state" => nil }])
    end
  end

  context "with an era-migrated record deleted and then re-saved" do
    before do
      write_v1_record
      registry = mint_v2!
      @adapter = adapter_for(registry, "Account")
      @adapter.delete("a1")
      @adapter.save(account_instance(registry, "a1", amount: { "cents" => 42 }, kind: { "label" => "business" },
                                                     denomination: { "code" => "USD" }))
    end

    it "lets the re-save win" do
      expect(@adapter.find("a1").amount.to_h).to eq(cents: 42)
    end

    it "counts the revived record once" do
      expect(@adapter.count).to eq(1)
    end
  end

  UNMAPPED_REFUSAL = Regexp.new(
    "cannot translate kind.label: \"mystery\" has no mapping in its convert's values: table. " \
    "Add \"mystery\" => \\.\\.\\. to cover it"
  )

  context "with a convert meeting an unmapped value" do
    before do
      write_v1_record(cost: { "cents" => 5, "currency" => "USD" }, kind: { "label" => "mystery" }, legacy_note: { "text" => "x" })
    end

    it "refuses the whole mint" do
      expect { mint_v2! }.to raise_error(Hecks::Runtime::WiringError, UNMAPPED_REFUSAL)
    end

    it "never half-births the era", :aggregate_failures do
      expect { mint_v2! }.to raise_error(Hecks::Runtime::WiringError)
      expect(count_of("hecks_eras", "domain = 'Ledger'")).to eq("1")
    end
  end

  PLACEHOLDER_ERA_INSERT =
    "INSERT INTO hecks_eras (domain, ordinal, hash, label, held_text, watermark, held_digest, canon_form) " \
    "VALUES ('Ledger', 99, 'placeholder-hash', 'xxxxxx', 'placeholder', 1, 'placeholder-digest', 1)".freeze

  # Targets the mechanism directly, since the pre-mint audit catches every DSL-level refusal
  # first. PG::Connection#transaction is a bare `BEGIN`/`COMMIT` without savepoints, so
  # ensure_head_snapshot! run mid-transaction must not commit it, or the `ROLLBACK` undoes nothing.
  context "with ensure_head_snapshot! run inside a transaction that is rolled back" do
    def run_snapshot_inside_a_rolled_back_transaction
      acct = load_registry(V1_SOURCE).bluebooks.values.first.aggregate("Acct")
      with_db do |db|
        lineage = Hecks::Adapters::PostgresEra::Lineage.new(db, "Ledger")
        db.exec("BEGIN")
        db.exec_params(PLACEHOLDER_ERA_INSERT)
        lineage.ensure_head_snapshot!(acct.storage_name, 99)
        # Stands in for mint_era!'s rescue: a later failure rolls the whole mint back.
        db.exec("ROLLBACK")
      end
    end

    before do
      check!(V1_SOURCE)
      run_snapshot_inside_a_rolled_back_transaction
    end

    it "does not commit the era row" do
      expect(count_of("hecks_eras", "domain = 'Ledger' AND ordinal = 99")).to eq("0")
    end

    it "does not commit the snapshot table" do
      expect(with_db { |db| db.exec("SELECT to_regclass('ledger_acct_head_snapshot_99') IS NULL AS gone")[0]["gone"] }).to eq("t")
    end
  end

  COLLIDE_V1 = <<~BLUEBOOK.freeze
    Hecks.bluebook "Collide" do
      aggregate "Acct" do
        identified_by :kind
        attribute :amount, Money
        attribute :kind, Kind
        reference_to Team
        value_object "Money" do
          attribute :cents, Integer
        end
        value_object "Kind" do
          attribute :value, String
        end
      end
      aggregate "Team" do
        identified_by :name
        attribute :name, TeamName
        value_object "TeamName" do
          attribute :value, String
        end
      end
    end
  BLUEBOOK

  COLLIDE_V2 = COLLIDE_V1.sub('aggregate "Acct"', 'aggregate "Account"').freeze

  COLLIDING_MOVE_REFUSAL =
    /cannot move amount\.cents to: team_ref\.detail: team_ref already holds "team-1", not a value this can nest under/

  # A move destination that collides with an existing scalar (a reference_to field, a bare id)
  # must refuse by name instead of overwriting it; mirrors spec/translation_language_spec.rb.
  # Bare `reference_to Team` (no `as:`) is deliberate: shadow_parse (era_guard.rb) must try a
  # normal parse first, or shadow mode's default mints `team_id` and breaks the edge lookup.
  context "with a move whose destination collides with an existing scalar" do
    def save_collide_record
      acct = check!(COLLIDE_V1).bluebooks.values.first.aggregate("Acct")
      state = { amount: { "cents" => 500 }, kind: { "value" => "biz" }, team: "team-1" }
      Hecks::Adapters::PostgresEra.new(aggregate: acct, settings: { database: LINEAGE_DB, domain: "Collide" })
                                  .save(Hecks::Runtime::Instance.new(aggregate: acct, id: "a1", state: state))
    end

    def colliding_edge
      <<~RUBY
        Hecks.data_translation("Collide", from: #{label_of(COLLIDE_V1).inspect}, to: #{label_of(COLLIDE_V2).inspect}) do
          aggregate("Account", was: "Acct") do
            rename :team, to: :team_ref
            move "amount.cents", to: "team_ref.detail"
          end
        end
      RUBY
    end

    it "refuses the mint by name, not silently" do
      save_collide_record

      expect { check!(COLLIDE_V2, translation_source: colliding_edge) }
        .to raise_error(Hecks::Runtime::WiringError, COLLIDING_MOVE_REFUSAL)
    end
  end

  # A post-cut row in a superseded era: frozen tail, old-world read, head blindness and
  # diverged_count are all checked against the same inserted row.
  context "with a post-cut row inserted into a superseded era" do
    def late_state
      JSON.generate(cost: { "cents" => 5, "currency" => "USD" }, kind: { "label" => "biz" }, legacy_note: { "text" => "late" })
    end

    # The row is inserted as the owner, standing in for a writer racing a live mint (RLS is
    # checked at statement time, not at commit); the fence specs show an ordinary role cannot.
    # Under test is what follows: the frozen tail, diverged_count and merge_tail.
    def insert_post_cut_row
      with_db do |db|
        ordinal = db.exec_params(
          "INSERT INTO hecks_journal_ledger (era, aggregate, aggregate_id, operation, state) " \
          "VALUES (1, 'acct', $1, 'save', $2) RETURNING ordinal",
          ["a9", late_state]
        )[0]["ordinal"]
        # ...plus the era-1 snapshot table that append would write; old_world.find reads it verbatim.
        db.exec_params("INSERT INTO ledger_acct_head_snapshot_1 (id, ordinal, state) VALUES ($1, $2, $3)",
                       ["a9", ordinal, late_state])
      end
    end

    before do
      write_v1_record
      mint_v2!
      @old_registry = check!(V1_SOURCE)
      insert_post_cut_row
    end

    it "resolves the old checkout at era 1" do
      expect(@old_registry.resolved_eras["Ledger"]).to eq(1)
    end

    it "keeps the row in the superseded era's partition" do
      eras = with_db { |db| db.exec("SELECT era FROM hecks_journal_ledger WHERE aggregate_id = 'a9'").map { |row| row["era"] } }

      expect(eras).to eq(["1"])
    end

    # ...an era-1 checkout still sees it, under the old storage name...
    it "lets an era-1 checkout still see it, under the old storage name" do
      old_world = Hecks::Adapters::PostgresEra.new(
        aggregate: @old_registry.bluebooks.values.first.aggregate("Acct"),
        settings:  { database: owner_url, domain: "Ledger", era: 1 }
      )

      expect(old_world.find("a9").cost.to_h).to eq(cents: 5, currency: "USD")
    end

    # ...the new head does not (the watermark is baked into the matview)...
    it "keeps it out of the new head" do
      expect(count_of("ledger_account_head", "id = 'a9'")).to eq("0")
    end

    it "counts it as diverged" do
      expect(with_db { |db| Hecks::Adapters::PostgresEra::Lineage.new(db, "Ledger").diverged_count(1) }).to eq(1)
    end
  end

  # Lock contention means the reordering failed; an RLS refusal after the mint commits is
  # expected. Only the first kind counts as a failure. The writer's counts, shared with its thread.
  LineageWriterProbe = Struct.new(:ok, :lock_blocked, :fence_refused, :stop)

  ANCESTOR_TAIL_INSERT = "INSERT INTO hecks_journal_ledger (era, aggregate, aggregate_id, operation, state) " \
                         "VALUES (1, 'acct', $1, 'save', $2)".freeze

  # One concurrency proof: the seeded ancestor tail, a background writer and a live mint race.
  context "with a background writer racing a live mint" do
    # An aggregate name the bluebook never declares, so the mint's audit never sees these rows;
    # the partition-level locks are still exercised.
    def probe_once(connection, probe)
      connection.exec(journal_insert(1, "live", aggregate: "unrelated_probe"))
      probe.ok += 1
    rescue PG::Error => e
      /lock timeout|canceling statement/i.match?(e.message) ? probe.lock_blocked += 1 : probe.fence_refused += 1
    end

    def probing_writer(probe)
      Thread.new do
        writer = PG.connect(owner_url)
        writer.exec("SET lock_timeout = '500ms'")
        probe_once(writer, probe) until probe.stop
        writer.close
      end
    end

    # A real ancestor tail makes the matview build slow enough to widen any lock window.
    def insert_ancestor_tail(count)
      with_db do |db|
        count.times do |i|
          state = JSON.generate(cost: { "cents" => i, "currency" => "USD" }, kind: { "label" => "biz" },
                                legacy_note: { "text" => "x" })
          db.exec_params(ANCESTOR_TAIL_INSERT, ["bulk-#{i}", state])
        end
      end
    end

    def mint_while_probing
      probe = LineageWriterProbe.new(0, 0, 0, false)
      writer = probing_writer(probe)
      sleep 0.05 # let the writer get a few writes in before the mint starts
      mint_v2!
      probe.stop = true
      writer.join
      probe
    end

    before do
      write_v1_record
      insert_ancestor_tail(3_000)
      @probe = mint_while_probing
    end

    it "an ordinary writer is never blocked by a mint — it keeps writing through it" do
      expect(@probe.ok).to be > 0
    end

    it "never waits on advance_era!'s AccessExclusiveLock, held for the commit and not the matview build" do
      expect(@probe.lock_blocked).to eq(0)
    end
  end

  MERGE_CONFLICT_REFUSAL = "cannot merge the tail of Ledger: touched by both worlds since the cut — account#a1. " \
                           "Name each winner (--winner <id>=old or --winner <id>=new), then run hecks merge_tail again. " \
                           "A winner takes the WHOLE record — the aggregate is the consistency boundary, so the " \
                           "loser's edits are discarded even where they touched different attributes".freeze

  # Saves one record into the world of `era`, as that checkout's adapter would.
  def save_in_world(registry, aggregate_name, era, id, **state)
    aggregate = registry.bluebooks.values.first.aggregate(aggregate_name)
    world = Hecks::Adapters::PostgresEra.new(aggregate: aggregate, settings: { database: LINEAGE_DB, domain: "Ledger", era: era })
    world.save(Hecks::Runtime::Instance.new(aggregate: aggregate, id: id, state: state))
  end

  # An old checkout keeps writing era 1 after era 2 was minted: `a1` in both worlds, `a9` in one.
  # Answers era 2's registry.
  def fork_worlds
    write_v1_record
    new_registry = mint_v2!
    save_in_world(new_registry, "Account", 2, "a1", amount: { "cents" => 999 }, kind: { "label" => "business" },
                                                    denomination: { "code" => "USD" }, status: "open")
    old_registry = check!(V1_SOURCE)
    save_in_world(old_registry, "Acct", 1, "a1", cost: { "cents" => 111, "currency" => "USD" },
                                                 kind: { "label" => "biz" }, legacy_note: { "text" => "old edit" })
    save_in_world(old_registry, "Acct", 1, "a9", cost: { "cents" => 5, "currency" => "EUR" },
                                                 kind: { "label" => "pers" }, legacy_note: { "text" => "late" })
    new_registry
  end

  def merge_tail!(registry, **extra)
    Hecks::Adapters::PostgresEra::LineageManager.merge!(
      registry: registry, bluebook: registry.bluebooks.values.first, settings: { database: LINEAGE_DB }, **extra
    )
  end

  def head_states
    with_db do |db|
      db.exec("SELECT id, state FROM ledger_account_head ORDER BY id").to_h { |row| [row["id"], JSON.parse(row["state"])] }
    end
  end

  def ancestor_rows = with_db { |db| db.exec("SELECT ordinal, state FROM hecks_journal_ledger_era_1 ORDER BY ordinal").values }

  context "with both worlds having written since the cut" do
    before { @new_registry = fork_worlds }

    it "refuses both-worlds conflicts by name, until each has a winner" do
      expect { merge_tail!(@new_registry) }.to raise_error(Hecks::Runtime::WiringError, MERGE_CONFLICT_REFUSAL)
    end

    context "when merged with the new world winning" do
      before do
        @ancestor_before = ancestor_rows
        merge_tail!(@new_registry, winners: { "a1" => "new" })
      end

      it "interleaves the declared winner and the lone old-world write, append-only", :aggregate_failures do
        expect(head_states["a9"].slice("amount", "denomination", "kind"))
          .to eq("amount" => { "cents" => 5 }, "denomination" => { "code" => "EUR" }, "kind" => { "label" => "personal" })
        expect(head_states["a1"]["amount"]).to eq("cents" => 999)
      end

      it "leaves nothing diverged" do
        expect(with_db { |db| Hecks::Adapters::PostgresEra::Lineage.new(db, "Ledger").diverged_count(1) }).to eq(0)
      end

      it "never rewrites the ancestor era's rows" do
        expect(ancestor_rows).to eq(@ancestor_before)
      end
    end

    context "when merged with the old world winning" do
      before { merge_tail!(@new_registry, winners: { "a1" => "old" }) }

      it "restores the old world's translated state as the newest row", :aggregate_failures do
        expect(head_states["a1"]["amount"]).to eq("cents" => 111)
        expect(head_states["a1"]["denomination"]).to eq("code" => "USD")
      end
    end
  end

  IDENTITY_PATH_REFUSAL = "cannot mint an era for Ledger::Account: its identity path changed (kind.label → amount.cents), " \
                          "and that is a re-keying, not a translation — stored ids were minted under kind.label, and no " \
                          "rule declares rows the same entity under a new key. Keep the identity path, declare a rekey " \
                          "rule, or migrate the data explicitly".freeze

  it "refuses an identity-path change as a re-keying, not a translation" do
    rekeyed = V2_SOURCE.sub("identified_by :kind", "identified_by :amount")
    write_v1_record

    expect { check!(rekeyed, translation_source: edge_source(from: label_of(V1_SOURCE), to: label_of(rekeyed))) }
      .to raise_error(Hecks::Runtime::WiringError, IDENTITY_PATH_REFUSAL)
  end

  context "with era 2 minted twice, the second boot losing the advisory-lock race" do
    before do
      write_v1_record
      mint_v2!
      # the "loser": a second boot of the same drifted shape finds the era
      # already born and proceeds into it — no error, no duplicate row
      @loser = mint_v2!
    end

    # the raw race inside the lock: a direct second mint of the same
    # ordinal re-checks under the lock and stands down
    def second_mint_of_ordinal_two
      with_db do |db|
        lineage = Hecks::Adapters::PostgresEra::Lineage.new(db, "Ledger")
        lineage.mint_era!(ordinal: 2, hash: "x", label: "x", held_text: "x", aggregates: [], edges: [])
      end
    end

    it "adopts the era the winner minted" do
      expect(@loser.resolved_eras["Ledger"]).to eq(2)
    end

    it "leaves no duplicate era row" do
      expect(count_of("hecks_eras", "domain = 'Ledger'")).to eq("2")
    end

    it "stands down a direct second mint of the same ordinal, keeping the first label", :aggregate_failures do
      expect(second_mint_of_ordinal_two).to be(false)
      label = with_db { |db| db.exec("SELECT label FROM hecks_eras WHERE domain = 'Ledger' AND ordinal = 2")[0]["label"] }
      expect(label).to eq(label_of(V2_SOURCE))
    end
  end

  PRICING_V1 = <<~BLUEBOOK.freeze
    Hecks.bluebook "Pricing" do
      aggregate "Quote" do
        identified_by :sku

        attribute :sku, Sku
        attribute :price_cents, Cents

        value_object "Sku" do
          attribute :value, String
        end

        value_object "Cents" do
          attribute :value, Integer
        end
      end
    end
  BLUEBOOK

  PRICING_V2 = <<~BLUEBOOK.freeze
    Hecks.bluebook "Pricing" do
      aggregate "Quote" do
        identified_by :sku

        attribute :sku, Sku
        attribute :price_dollars, Dollars

        value_object "Sku" do
          attribute :value, String
        end

        value_object "Dollars" do
          attribute :value, Float
        end
      end
    end
  BLUEBOOK

  UNAPPROVED_EDGE_REFUSAL = "cannot mint era 2 of Pricing: this edge carries a compute or rekey rule, and the audit's " \
                            "human-approved sample is its only verification — run hecks audit_translation with " \
                            "--approve, then boot again".freeze

  JOURNAL_ADVANCED_REFUSAL = /
    the\ journal\ advanced\ past\ the\ approved\ review\ \(ordinal\ 1\ reviewed,\ 2\ now\)\ —\ the\ samples
    \ a\ human\ approved\ no\ longer\ cover\ the\ data;\ re-run\ hecks\ audit_translation\ with\ --approve
  /x

  # One edge's lifecycle: refuse without approval, approve, invalidate by advancing the journal,
  # approve again, mint, then compare the compiled SQL to the in-process reference.
  context "with a compute rule on the edge from a saved quote" do
    before do
      pricing_v1 = load_registry(PRICING_V1)
      check_loaded!(pricing_v1, PRICING_V1)
      @quote = pricing_v1.bluebooks.values.first.aggregate("Quote")
      @quotes = Hecks::Adapters::PostgresEra.new(aggregate: @quote, settings: { database: LINEAGE_DB, domain: "Pricing" })
      save_quote("q1", 1250)
      @drifted = load_registry(PRICING_V2, translation_source: compute_edge)
    end

    def save_quote(id, cents)
      @quotes.save(Hecks::Runtime::Instance.new(aggregate: @quote, id: id, state: { price_cents: { "value" => cents } }))
    end

    def compute_edge
      <<~RUBY
        Hecks.data_translation("Pricing", from: #{label_of(PRICING_V1).inspect}, to: #{label_of(PRICING_V2).inspect}) do
          aggregate("Quote") do
            compute "price_cents", to: "price_dollars",
                    sql: "jsonb_build_object('value', (price_cents::jsonb ->> 'value')::numeric / 100)"
          end
        end
      RUBY
    end

    # The approval binds to the edge's content and the journal's high-water ordinal at review
    # time, in the database itself.
    def approve_compute_edge!
      with_db do |db|
        Hecks::Adapters::PostgresEra::Lineage.new(db, "Pricing").record_approval!(
          from: label_of(PRICING_V1), to: label_of(PRICING_V2),
          edge_digest: Hecks::Translation::Audit.edge_digest(@drifted.translations.first)
        )
      end
    end

    # a compute's only verification is the audit's human-approved sample
    # — without the approval token the mint refuses, non-interactively
    it "refuses the mint without the approval token" do
      expect { check_loaded!(@drifted, PRICING_V2) }.to raise_error(Hecks::Runtime::WiringError, UNAPPROVED_EDGE_REFUSAL)
    end

    it "refuses the mint once the journal advanced past the approved review" do
      approve_compute_edge!
      save_quote("q2", 300)

      expect { check_loaded!(@drifted, PRICING_V2) }.to raise_error(Hecks::Runtime::WiringError, JOURNAL_ADVANCED_REFUSAL)
    end

    context "when approved and minted" do
      before do
        approve_compute_edge!
        check_loaded!(@drifted, PRICING_V2)
      end

      it "evaluates the compute inside the compiled matview — its SQL is its only implementation" do
        matview = "pricing_quote_lineage_2_#{label_of(PRICING_V2)}"
        compiled = with_db { |db| JSON.parse(db.exec("SELECT state FROM #{matview} WHERE aggregate_id = 'q1'")[0]["state"]) }

        expect(compiled).to eq("price_dollars" => { "value" => 12.5 }, "sku" => { "value" => "q1" })
      end

      # ...and the in-process reference transform deliberately did not —
      # compute is exempt from the equivalence gate; there is nothing
      # in-process to hold it against.
      it "leaves the in-process reference transform unchanged" do
        declared = @drifted.translations.first.for_aggregate("Quote")
        rules = Hecks::Ports::Persistence::Lineage.from_declared(declared, "Quote")
        entry = Hecks::Ports::Persistence::Entry.new(operation: "save", id: "q1", state: { price_cents: { "value" => 1250 } })

        expect(rules.translate(entry).state).to eq(price_cents: { "value" => 1250 })
      end

      it "serves the head with the computed value" do
        v2_quote = @drifted.bluebooks.values.first.aggregate("Quote")
        head = Hecks::Adapters::PostgresEra.new(aggregate: v2_quote, settings: { database: LINEAGE_DB, domain: "Pricing" })

        expect(head.find("q1").price_dollars.to_h).to eq(value: 12.5)
      end
    end
  end

  ROSTER_V1 = <<~BLUEBOOK.freeze
    Hecks.bluebook "Roster" do
      aggregate "Person" do
        identified_by :name

        attribute :name,  PersonName
        attribute :title, PersonTitle

        value_object "PersonName" do
          attribute :value, String
        end

        value_object "PersonTitle" do
          attribute :value, String
        end
      end
    end
  BLUEBOOK

  ROSTER_V2 = <<~BLUEBOOK.freeze
    Hecks.bluebook "Roster" do
      aggregate "Person" do
        # NOT optional: an identity must be wholly known (ADR 0029) — every
        # V1 row is rekeyed to a real email by the translation below before
        # V2 identity ever matters, so nothing here actually depends on
        # `email` being absent at any point this scenario exercises.
        identified_by :email

        attribute :name,  PersonName
        attribute :title, PersonTitle
        attribute :email, PersonEmail

        value_object "PersonName" do
          attribute :value, String
        end

        value_object "PersonTitle" do
          attribute :value, String
        end

        value_object "PersonEmail" do
          attribute :value, String
        end
      end
    end
  BLUEBOOK

  ROSTER_REKEY_EDGE = <<~RUBY.freeze
    Hecks.data_translation("Roster", from: %<from>s, to: %<to>s) do
      aggregate("Person") do
        rekey sql: "CASE ((__s -> 'name') ->> 'value') WHEN 'Chris Young' THEN 'chris@example.com' END"
        # `rekey` explains the NEW IDENTITY (the row's id going forward);
        # it says nothing about the stored `email` ATTRIBUTE's own value
        # for an old row read through this translation, which is a
        # separate question `unsafe_additions` asks. Same value either
        # way for this single-row fixture, but a real answer, not a
        # coincidence of the rekey SQL happening to be readable twice.
        backfill :email, default: "chris@example.com"
      end
    end
  RUBY

  # Same approval lifecycle as the compute example: the record resolves under its new id
  # while the raw journal stays keyed to the old one.
  context "with a rekey of an aggregate's identity on the edge from a saved person" do
    before do
      roster_v1 = load_registry(ROSTER_V1)
      check_loaded!(roster_v1, ROSTER_V1)
      person = roster_v1.bluebooks.values.first.aggregate("Person")
      people = Hecks::Adapters::PostgresEra.new(aggregate: person, settings: { database: LINEAGE_DB, domain: "Roster" })
      state = { name: { "value" => "Chris Young" }, title: { "value" => "CEO" } }
      people.save(Hecks::Runtime::Instance.new(aggregate: person, id: "Chris Young", state: state))
      @drifted = load_registry(ROSTER_V2, translation_source: rekey_edge)
    end

    def rekey_edge = format(ROSTER_REKEY_EDGE, from: label_of(ROSTER_V1).inspect, to: label_of(ROSTER_V2).inspect)

    def approve_rekey_edge!
      with_db do |db|
        Hecks::Adapters::PostgresEra::Lineage.new(db, "Roster").record_approval!(
          from: label_of(ROSTER_V1), to: label_of(ROSTER_V2),
          edge_digest: Hecks::Translation::Audit.edge_digest(@drifted.translations.first)
        )
      end
    end

    # a rekey's only verification is the audit's human-approved sample,
    # same as compute — the mint refuses non-interactively without it
    it "refuses the mint without the approval token" do
      expect { check_loaded!(@drifted, ROSTER_V2) }
        .to raise_error(Hecks::Runtime::WiringError, /this edge carries a compute or rekey rule/)
    end

    context "when approved and minted" do
      before do
        approve_rekey_edge!
        check_loaded!(@drifted, ROSTER_V2)
      end

      def head
        person = @drifted.bluebooks.values.first.aggregate("Person")
        Hecks::Adapters::PostgresEra.new(aggregate: person, settings: { database: LINEAGE_DB, domain: "Roster" })
      end

      def rows_under(id)
        matview = "roster_person_lineage_2_#{label_of(ROSTER_V2)}"
        with_db { |db| db.exec("SELECT state FROM #{matview} WHERE aggregate_id = '#{id}'").ntuples }
      end

      # the compiled matview resolves the record under its new id, and
      # only its new id — the raw journal row is untouched (still keyed
      # "Chris Young"), but nothing reads it directly
      it "resolves the record under its new id, and only its new id" do
        expect([rows_under("chris@example.com"), rows_under("Chris Young")]).to eq([1, 0])
      end

      it "never rewrites the immutable journal" do
        expect(count_of("hecks_journal_roster", "aggregate_id = 'Chris Young'")).to eq("1")
      end

      it "serves the record under its new id, and no longer under the old one" do
        found = head.find("chris@example.com")
        expected = [{ value: "Chris Young" }, { value: "CEO" }, nil]

        expect([found.name.to_h, found.title.to_h, head.find("Chris Young")]).to eq(expected)
      end
    end
  end

  context "with a fenced app role booted at the era its checkout speaks" do
    before do
      reset_app_role!
      write_v1_record
      mint_v2!(role: LINEAGE_ROLE)
    end

    def append_as_app_role(era) = as_app_role(journal_insert(era, "fenced-#{era}"))

    def partition_insert = journal_insert(1, "leaf", aggregate: "acct").sub("hecks_journal_ledger", "hecks_journal_ledger_era_1")

    # The fenced role must still boot; ensure_base!'s ALTER TABLE and REVOKE are owner-only.
    it "lets the fenced role still boot" do
      with_db(user: LINEAGE_ROLE) do |app|
        expect { Hecks::Adapters::PostgresEra::Lineage.new(app, "Ledger").ensure_base! }.not_to raise_error
      end
    end

    it "lets the role write the era its checkout speaks" do
      expect(append_as_app_role(2)).to eq(:allowed)
    end

    # A per-partition GRANT cannot express this: Postgres checks INSERT on the partitioned
    # parent for a routed insert and never consults the partition.
    it "fences the role out of era 1" do
      expect(append_as_app_role(1)).to match(/row-level security policy/i)
    end

    # a partition is no back door: the role is granted on the parent only
    it "gives the role no back door through a partition" do
      expect(as_app_role(partition_insert)).to match(/permission denied/i)
    end

    it "refuses the role an UPDATE and a DELETE" do
      refusals = ["UPDATE hecks_journal_ledger SET operation = 'delete'", "DELETE FROM hecks_journal_ledger"]
                 .map { |statement| as_app_role(statement) }

      expect(refusals).to all(match(/permission denied|row-level security/i))
    end

    # the owner is not fenced — mint and merge must reach every era
    it "does not fence the owner" do
      expect { with_db { |owner| owner.exec(journal_insert(1, "owner-write", aggregate: "acct")) } }.not_to raise_error
    end

    # Adversarial routing techniques against a naive check: a CTE, a function body and copy.
    # Postgres refuses copy from outright once RLS is enabled on the target; do not relax force
    # ROW LEVEL SECURITY without knowing that.
    it "cannot route an era-1 write around the fence through a CTE" do
      expect(as_app_role("WITH x AS (#{journal_insert(1, "cte")} RETURNING 1) SELECT * FROM x")).to match(/row-level security/i)
    end

    it "cannot route an era-1 write around the fence through a function body" do
      expect(as_app_role("DO $$ BEGIN #{journal_insert(1, "do-block")}; END $$")).to match(/row-level security/i)
    end

    def copy_from_stdin_message
      with_db(user: LINEAGE_ROLE) do |app|
        app.exec("COPY hecks_journal_ledger (era, aggregate, aggregate_id, operation, state) FROM STDIN")
        raise "COPY should not even be attempted under RLS"
      end
    rescue PG::Error => e
      e.message
    end

    it "cannot route an era-1 write around the fence through COPY" do
      expect(copy_from_stdin_message).to match(/COPY FROM not supported with row-level security/i)
    end
  end

  # A mint-shaped transaction is held open at the partition-attach point, the lock is probed
  # by name, then a concurrent write must go through.
  context "with a mint-shaped transaction held open at the partition-attach point" do
    before do
      write_v1_record
      mint_v2!
      label_of(V3_SOURCE)
      # Hold a mint-shaped transaction open with the next era's partition attached, uncommitted.
      @blocker = PG.connect(dbname: LINEAGE_DB)
      @blocker.exec("BEGIN")
      Hecks::Adapters::PostgresEra::Lineage.new(@blocker, "Ledger").ensure_partition!(3)
    end

    after do
      @blocker.exec("ROLLBACK")
      @blocker.close
    end

    def held_lock_mode
      with_db do |probe|
        probe.exec_params(
          "SELECT l.mode FROM pg_locks l JOIN pg_class c ON c.oid = l.relation " \
          "WHERE c.relname = $1 AND l.mode LIKE '%Exclusive%' ORDER BY l.mode LIMIT 1",
          ["hecks_journal_ledger"]
        )[0]&.fetch("mode")
      end
    end

    def write_during_mint
      with_db do |writer|
        writer.exec("SET lock_timeout = '2s'")
        writer.exec(journal_insert(2, "during-mint"))
        :allowed
      rescue PG::Error => e
        e.message.strip
      end
    end

    # the lock that attach took, named — ShareUpdateExclusive conflicts
    # with neither reads nor inserts; AccessExclusive (what
    # CREATE ... PARTITION OF takes) conflicts with both
    it "holds only a lock that conflicts with neither reads nor inserts" do
      expect(held_lock_mode).to eq("ShareUpdateExclusiveLock")
    end

    it "lets an old checkout keep writing its own era THROUGH a mint — the fork survives the window" do
      expect(write_during_mint).to eq(:allowed)
    end
  end

  # append holds pg_advisory_xact_lock(hashtext('hecks_ordinal:' || domain)) for its whole
  # transaction, a different key from the mint/merge lock. Holding it by hand must block a save.
  context "with the ordinal advisory lock held by hand" do
    def ordinal_lock_holder
      holder = PG.connect(dbname: LINEAGE_DB)
      holder.exec("BEGIN")
      holder.exec_params("SELECT pg_advisory_xact_lock(hashtext('hecks_ordinal:' || $1))", ["Ledger"])
      holder
    end

    def second_account_instance(registry)
      state = { cost: { "cents" => 1, "currency" => "USD" }, kind: { "label" => "biz" }, legacy_note: { "text" => "x" } }
      Hecks::Runtime::Instance.new(aggregate: registry.bluebooks.values.first.aggregate("Acct"), id: "a2", state: state)
    end

    def release_lock(holder, blocked)
      holder.exec("COMMIT")
      blocked.join(2)
    end

    # Saves while the lock is held, then releases it; answers whether the save was still waiting
    # while the lock was held, and whether it still was after the release.
    def save_while_lock_held
      registry = check!(V1_SOURCE)
      adapter = adapter_for(registry, "Acct")
      holder = ordinal_lock_holder
      blocked = Thread.new { adapter.save(second_account_instance(registry)) }
      sleep 0.3
      waiting = blocked.alive? # still waiting on the lock ; the write has not happened
      release_lock(holder, blocked)
      [waiting, blocked.alive?]
    ensure
      holder&.close
    end

    before { @waiting, @still_alive = save_while_lock_held }

    it "serializes concurrent plain writes against EACH OTHER — a write waits for the lock" do
      expect(@waiting).to be(true)
    end

    # released the instant the lock was — not before
    it "completes the write the instant the lock is released", :aggregate_failures do
      expect(@still_alive).to be(false)
      expect(with_db { |db| db.exec("SELECT ordinal FROM hecks_journal_ledger WHERE aggregate_id = 'a2'")[0] }).not_to be_nil
    end
  end

  context "with a role that rebooted into its OWN now-superseded era" do
    before do
      reset_app_role!
      check!(V1_SOURCE, role: LINEAGE_ROLE)
      write_v1_record
      # a plain owner mint, no role at all
      mint_v2!
      # the same role reboots and correctly recognizes itself as
      # superseded (the "matched" branch) — nothing about its own
      # settings changed; the schema moved out from under it
      check!(V1_SOURCE, role: LINEAGE_ROLE)
    end

    it "cannot write it — nothing about that boot may reopen the schema a mint already closed" do
      expect(as_app_role(journal_insert(1, "after-reboot"))).to match(/row-level security/i)
    end
  end

  # Postgres exempts a superuser or BYPASSRLS role from every policy, force included, so boot
  # checks pg_roles and refuses by default; allow_superuser boots anyway and warns.
  # The ambient connection is a superuser locally and on CI (`PGUSER` is postgres); the
  # examples skip when it is not.
  def ambient_role
    with_db do |db|
      db.exec("SELECT rolname, (rolsuper OR rolbypassrls) AS exempt FROM pg_roles WHERE rolname = current_user")[0]
    end
  end

  def check_as_ambient!(source, **extra_settings)
    registry = load_registry(source)
    Hecks::Adapters::PostgresEra::LineageManager.check!(
      registry: registry, bluebook: registry.bluebooks.values.first, current_text: source,
      settings: { database: LINEAGE_DB }.merge(extra_settings)
    )
    registry
  end

  context "with an ambient connection that is a superuser" do
    let(:ambient) { ambient_role }

    before do
      reason = "the ambient Postgres role #{ambient["rolname"]} is neither a superuser nor BYPASSRLS here"
      skip reason if ambient["exempt"] != "t"
    end

    def superuser_refusal
      lead = "cannot boot Ledger: PostgresEra's era write-fence is row-level security, and this " \
             "connection's role #{ambient["rolname"].inspect} is "
      closing = "#{Regexp.escape("Connect as an ordinary role instead")}.*" \
                "#{Regexp.escape("or declare `allow_superuser true` in the same persisted_by block")}"
      Regexp.new("\\A#{Regexp.escape(lead)}(a superuser|granted BYPASSRLS).*#{closing}", Regexp::MULTILINE)
    end

    def fence_void_warning
      Regexp.new("#{Regexp.escape("[hecks] Ledger: booting PostgresEra as #{ambient["rolname"].inspect}, ")}.*" \
                 "#{Regexp.escape("under allow_superuser — the era write-fence is void for this connection")}")
    end

    it "refuses to boot over it by default — the era write-fence is void for it, and says so" do
      expect { check_as_ambient!(V1_SOURCE) }.to raise_error(Hecks::Runtime::WiringError, superuser_refusal)
    end

    it "refuses before provisioning anything — a refused boot holds no era", :aggregate_failures do
      expect { check_as_ambient!(V1_SOURCE) }.to raise_error(Hecks::Runtime::WiringError)
      expect(with_db { |db| db.exec("SELECT to_regclass('hecks_eras') IS NULL AS absent")[0]["absent"] }).to eq("t")
    end

    it "boots over it under allow_superuser — and says the fence is void" do
      expect { check_as_ambient!(V1_SOURCE, allow_superuser: true) }.to output(fence_void_warning).to_stderr
    end

    # the string spelling opts in too, and a quiet reboot warns again —
    # the fence is just as void the second time
    it "warns on every boot, whichever way allow_superuser is spelled", :aggregate_failures do
      expect { check_as_ambient!(V1_SOURCE, allow_superuser: true) }.to output(fence_void_warning).to_stderr
      expect { check_as_ambient!(V1_SOURCE, "allow_superuser" => true) }.to output(fence_void_warning).to_stderr
    end

    # a stored `false` is a real answer, not an absent key — still refused
    it "still refuses a stored false" do
      expect { check_as_ambient!(V1_SOURCE, allow_superuser: false, "allow_superuser" => true) }
        .to raise_error(Hecks::Runtime::WiringError, /era write-fence is row-level security/)
    end

    it "holds one era after the boots", :aggregate_failures do
      expect { check_as_ambient!(V1_SOURCE, allow_superuser: true) }.to output(fence_void_warning).to_stderr
      expect(count_of("hecks_eras", "domain = 'Ledger'")).to eq("1")
    end
  end

  SUPERSEDED_WRITE_REFUSAL = "cannot write acct for Ledger: this checkout booted era 1, which era 2 has superseded — its shape " \
                             "was replaced by a mint, and a write here would land in a partition no newer head reads. Reads " \
                             "still work; pull the current bluebook and reboot to write again.".freeze

  # Proven as the owner, so the refusal must come from the adapter (WiringError before any
  # INSERT), not from the RLS policy. One old checkout is checked from every side at once.
  context "with a held-but-superseded checkout" do
    before do
      write_v1_record
      mint_v2!
      # the matched branch: an old checkout boots, and knows it is stale
      @old_registry = check!(V1_SOURCE)
    end

    def acct = @old_registry.bluebooks.values.first.aggregate("Acct")

    def late_acct_state
      { cost: { "cents" => 5, "currency" => "USD" }, kind: { "label" => "biz" }, legacy_note: { "text" => "late" } }
    end

    # exactly the settings RepositoryFactory.build merges in for that boot
    def old_world
      settings = { database: owner_url, domain: "Ledger", era: @old_registry.resolved_eras["Ledger"],
                   superseded_by: @old_registry.superseded_eras["Ledger"] }
      Hecks::Adapters::PostgresEra.new(aggregate: acct, settings: settings)
    end

    it "marks the old checkout as booted at era 1 and superseded by era 2", :aggregate_failures do
      expect(@old_registry.resolved_eras["Ledger"]).to eq(1)
      expect(@old_registry.superseded_eras["Ledger"]).to eq(2)
    end

    it "carries no such mark on a current-era boot", :aggregate_failures do
      current = mint_v2!

      expect(current.resolved_eras["Ledger"]).to eq(2)
      expect(current.superseded_eras["Ledger"]).to be_nil
    end

    it "refuses its own save in-process, naming the newer era" do
      expect { old_world.save(Hecks::Runtime::Instance.new(aggregate: acct, id: "a9", state: late_acct_state)) }
        .to raise_error(Hecks::Runtime::WiringError, SUPERSEDED_WRITE_REFUSAL)
    end

    it "refuses its own atomic_put in-process, naming the newer era" do
      entry = Hecks::Ports::Persistence::Entry.new(operation: "save", id: "a9", state: late_acct_state)

      expect { old_world.atomic_put(entry) }.to raise_error(Hecks::Runtime::WiringError, SUPERSEDED_WRITE_REFUSAL)
    end

    it "refuses its own delete in-process, naming the newer era" do
      expect { old_world.delete("a1") }.to raise_error(Hecks::Runtime::WiringError, SUPERSEDED_WRITE_REFUSAL)
    end

    it "still serves its reads", :aggregate_failures do
      world = old_world

      expect(world.find("a1").cost.to_h).to eq(cents: 100, currency: "USD")
      expect(world.find("a9")).to be_nil
      expect(world.count).to eq(1)
    end

    it "diverges nothing" do
      expect(with_db { |db| Hecks::Adapters::PostgresEra::Lineage.new(db, "Ledger").diverged_count(1) }).to eq(0)
    end
  end

  # One mint checked from four angles; each only means something read against the same two roles,
  # so the outcome does not depend on which role is asking.
  context "with two roles, one of which minted era 2" do
    def old_role = "#{LINEAGE_ROLE}_old"

    def new_role = "#{LINEAGE_ROLE}_new"

    def write_as(role, era) = as_role(role, journal_insert(era, "by-#{role}"))

    before do
      reset_role!(old_role)
      reset_role!(new_role)
      check!(V1_SOURCE, role: old_role)
      write_v1_record
    end

    it "lets the old role write era 1 while it is current" do
      expect(write_as(old_role, 1)).to eq(:allowed)
    end

    context "when the new role minted era 2" do
      before { mint_v2!(role: new_role) }

      it "lets the new role write era 2" do
        expect(write_as(new_role, 2)).to eq(:allowed)
      end

      # ...and so does the old role: any role granted INSERT may write whatever era is current.
      it "lets the old role write era 2 too" do
        expect(write_as(old_role, 2)).to eq(:allowed)
      end

      # no role may write era 1 once era 2 has materialized
      it "lets no role write era 1" do
        expect([write_as(old_role, 1), write_as(new_role, 1)]).to all(match(/row-level security/i))
      end
    end
  end

  def era_two_account = load_registry(V2_SOURCE).bluebooks.values.first.aggregate("Account")

  # Saves a record into era 2's head through the era-2 adapter.
  def save_era_two_record(id, label)
    account = era_two_account
    adapter = Hecks::Adapters::PostgresEra.new(aggregate: account, settings: { database: LINEAGE_DB, domain: "Ledger" })
    state = { amount: { "cents" => 250 }, kind: { "label" => label }, denomination: { "code" => "USD" } }
    adapter.save(Hecks::Runtime::Instance.new(aggregate: account, id: id, state: state))
  end

  def layered_rows(label)
    table = PG::Connection.quote_ident("ledger_account_lineage_3_#{label}")
    with_db { |db| db.exec("SELECT aggregate_id, operation, state FROM #{table} ORDER BY aggregate_id").values }
  end

  def matview_definition(label)
    with_db do |db|
      db.exec_params("SELECT definition FROM pg_matviews WHERE matviewname = $1",
                     ["ledger_account_lineage_3_#{label}"])[0]["definition"]
    end
  end

  # The same rows from a from-scratch build over the whole edge chain, not the layered one.
  def full_build_rows(source, edges, label)
    with_db do |db|
      lineage = Hecks::Adapters::PostgresEra::Lineage.new(db, "Ledger")
      chain = Hecks::Adapters::PostgresEra::LineageManager.edge_chain(
        load_registry(source, translation_source: edges), load_registry(source).bluebooks.values.first, lineage.eras[0..-2], label
      )
      db.exec("SELECT aggregate_id, operation, state FROM (#{lineage.chain_sql(era_two_account, 3, chain)}) full_build " \
              "ORDER BY aggregate_id").values
    end
  end

  # The layered build (reading era 2's matview) and a from-scratch full build must agree row
  # for row; both run against one mint through era 3.
  context "with era 3 minted over era 2's matview" do
    before do
      write_v1_record
      mint_v2!
      save_era_two_record("business", "business")
      @l2 = label_of(V2_SOURCE)
      @l3 = label_of(V3_SOURCE)
      @edges = "#{v1_to_v2_edge}\n#{edge_source_v3(from: @l2, to: @l3)}"
      check!(V3_SOURCE, translation_source: @edges)
    end

    it "builds era 3 from era 2's matview, not from raw history" do
      expect(matview_definition(@l3)).to include("ledger_account_lineage_2_#{@l2}")
    end

    it "answers the layered build equal to the full one", :aggregate_failures do
      layered = layered_rows(@l3)

      expect(layered).to eq(full_build_rows(V3_SOURCE, @edges, @l3))
      expect(layered).not_to be_empty
    end
  end

  # The same equivalence for a rekey, which reaches layered_chain_sql's id_column case
  # (Translation::RuleCompiler.id_case) that a rename edge never does; without it a rekey could
  # preview one answer at audit time and mint another. Same one-mint, two-build shape.
  context "with era 3 a rekey of the identity, over era 2's matview" do
    before do
      write_v1_record
      mint_v2!
      # more era-2 traffic; kind "personal" avoids colliding with "business" on the same new id
      # (a rekey collapses onto `kind.label`), which would trip the audit's count-preservation gate.
      save_era_two_record("personal", "personal")
      @l2 = label_of(V2_SOURCE)
      @l3 = label_of(V3_REKEYED_SOURCE)
      @edges = "#{v1_to_v2_edge}\n#{edge_source_v3_rekey(from: @l2, to: @l3)}"
    end

    # a rekey's only verification is the audit's human-approved sample; the mint refuses without it
    it "refuses the mint without the approval token" do
      expect { check!(V3_REKEYED_SOURCE, translation_source: @edges) }
        .to raise_error(Hecks::Runtime::WiringError, /this edge carries a compute or rekey rule/)
    end

    context "when approved and minted" do
      before do
        drifted = load_registry(V3_REKEYED_SOURCE, translation_source: @edges)
        edge = drifted.translations.find { |translation| translation.from == @l2 && translation.to == @l3 }
        with_db do |db|
          Hecks::Adapters::PostgresEra::Lineage.new(db, "Ledger")
                                               .record_approval!(from: @l2, to: @l3, edge_digest: Hecks::Translation::Audit.edge_digest(edge))
        end
        check!(V3_REKEYED_SOURCE, translation_source: @edges)
      end

      it "builds era 3 from era 2's matview, not from raw history" do
        expect(matview_definition(@l3)).to include("ledger_account_lineage_2_#{@l2}")
      end

      # ...and it agrees with the from-scratch build, ids included
      it "produces the identical id under a REKEY too — the layered build's id_column CASE agrees with the full one",
         :aggregate_failures do
        layered = layered_rows(@l3)

        expect(layered).to eq(full_build_rows(V3_REKEYED_SOURCE, @edges, @l3))
        expect(layered).not_to be_empty
        expect(layered.map(&:first)).to include("ref-business")
      end
    end
  end

  context "with an era-2 checkout writing after era 3 was minted" do
    # An old era-2 checkout keeps writing after era 3 cut its watermark; if the cut were
    # re-derived at query time the write would leak upward through era 2's matview.
    def stale_write
      account = era_two_account
      stale = Hecks::Adapters::PostgresEra.new(aggregate: account, settings: { database: LINEAGE_DB, domain: "Ledger", era: 2 })
      state = { amount: { "cents" => 999 }, kind: { "label" => "business" }, denomination: { "code" => "ZZZ" } }
      stale.save(Hecks::Runtime::Instance.new(aggregate: account, id: "business", state: state))
    end

    # The refresh is the point: a materialized tail is frozen anyway, so the cut only proves
    # itself when the definition is re-evaluated (the header promises it holds on a full refresh).
    def refreshed_head_and_divergence
      with_db do |db|
        db.exec("REFRESH MATERIALIZED VIEW #{PG::Connection.quote_ident("ledger_account_lineage_3_#{@l3}")}")
        [db.exec("SELECT id, state FROM ledger_account_head ORDER BY id").values,
         Hecks::Adapters::PostgresEra::Lineage.new(db, "Ledger").diverged_count(2)]
      end
    end

    before do
      write_v1_record
      mint_v2!
      @l3 = label_of(V3_SOURCE)
      check!(V3_SOURCE, translation_source: "#{v1_to_v2_edge}\n#{edge_source_v3(from: label_of(V2_SOURCE), to: @l3)}")
      stale_write
      @head, @diverged = refreshed_head_and_divergence
    end

    it "counts the stale write as diverged" do
      expect(@diverged).to eq(1)
    end

    it "keeps the layered build honouring the cut — the write never reaches era 3's head", :aggregate_failures do
      expect(@head.map(&:last).join).not_to include("999")
      expect(@head.map(&:last).join).not_to include("ZZZ")
    end
  end

  # Ask Postgres directly: on a fresh database relacl stays NULL (the guarded REVOKE in
  # provisioning.rb never fires when public holds nothing), so asserting non-nil would be wrong.
  def public_privilege(kind)
    with_db { |db| db.exec("SELECT has_table_privilege('public', 'hecks_journal_ledger', '#{kind}')")[0]["has_table_privilege"] }
  end

  it "journal rows accept no UPDATE or DELETE from PUBLIC — immutability by privilege" do
    check!(V1_SOURCE)

    expect(%w[UPDATE DELETE].map { |kind| public_privilege(kind) }).to eq(%w[f f])
  end

  # The reference semantics: the port-level entry-JSON transform.
  def reference_state(registry)
    declared = registry.translations.first.for_aggregate("Account")
    rules = Hecks::Ports::Persistence::Lineage.from_declared(declared, "Account")
    entry = Hecks::Ports::Persistence::Entry.new(operation: "save", id: "a1", state: v1_record_state)
    JSON.parse(JSON.generate(rules.translate(entry).state))
  end

  def compiled_state(matview)
    JSON.parse(with_db { |db| db.exec("SELECT state FROM #{matview} WHERE aggregate_id = 'a1'")[0]["state"] })
  end

  it "holds the code path and the compiled matview to the same answer — the cross-execution equivalence gate",
     :aggregate_failures do
    write_v1_record
    registry = mint_v2!
    matview = with_db { |db| db.exec("SELECT matviewname FROM pg_matviews")[0]["matviewname"] }

    expect(matview).to eq("ledger_account_lineage_2_#{label_of(V2_SOURCE)}")
    expect(compiled_state(matview)).to eq(reference_state(registry))
  end
end
