require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../../support/postgres_probe"

# Lineage in the PostgresEra adapter: partitioned journal, era rows, the one-transaction mint,
# and the head compiled as a chain of edges. Needs a reachable Postgres (see postgres_probe.rb).
RSpec.describe "lineage in the PostgresEra adapter", :io do
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

  def load_registry(source, translation_source: nil)
    registry = Hecks::Runtime::Registry.new
    loading = Hecks::Ports::Loading.bootstrap
    file = Tempfile.new(["lineage-", ".bluebook"])
    file.write(source)
    file.flush
    Hecks.with_registry(registry) do
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
    settings = { database: owner_url }
    settings[:role] = role if role
    Hecks::Adapters::PostgresEra::LineageManager.check!(
      registry: registry, bluebook: bluebook, current_text: source, settings: settings
    )
    registry
  end

  # A deployment's app role: a non-owner, the only kind of connection the era fence acts on.
  LINEAGE_ROLE = "hecks_lineage_spec_app".freeze

  def reset_app_role!
    db = PG.connect(dbname: LINEAGE_DB)
    begin
      db.exec("DROP OWNED BY #{LINEAGE_ROLE}")
    rescue PG::Error # rubocop:disable Lint/SuppressedException
    end
    db.close
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP ROLE IF EXISTS #{LINEAGE_ROLE}")
    admin.exec("CREATE ROLE #{LINEAGE_ROLE} LOGIN")
    admin.close
    db = PG.connect(dbname: LINEAGE_DB)
    db.exec("GRANT CONNECT ON DATABASE #{LINEAGE_DB} TO #{LINEAGE_ROLE}")
    db.exec("GRANT USAGE ON SCHEMA public TO #{LINEAGE_ROLE}")
    db.close
  end

  def as_app_role(sql)
    db = PG.connect(dbname: LINEAGE_DB, user: LINEAGE_ROLE)
    db.exec(sql)
    :allowed
  rescue PG::Error => e
    e.message.strip
  ensure
    db&.close
  end

  def hash_of(source)
    registry = load_registry(source)
    Hecks::Runtime::StorageShape.mint_hash(registry.bluebooks.values.first)
  end

  def label_of(source) = hash_of(source)[0, 6]

  def adapter_for(registry, aggregate_name)
    aggregate = registry.bluebooks.values.first.aggregate(aggregate_name)
    Hecks::Adapters::PostgresEra.new(aggregate: aggregate, settings: { database: owner_url, domain: "Ledger" })
  end

  def write_v1_record(state = nil)
    registry = check!(V1_SOURCE)
    adapter = adapter_for(registry, "Acct")
    instance = Hecks::Runtime::Instance.new(
      aggregate: registry.bluebooks.values.first.aggregate("Acct"), id: "a1",
      state: state || {
        cost:        { "cents" => 100, "currency" => "USD" },
        kind:        { "label" => "biz" },
        legacy_note: { "text" => "keep?" }
      }
    )
    adapter.save(instance)
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

  it "holds era 1 as a row on first boot, and boots the same shape quietly" do
    check!(V1_SOURCE)
    db = PG.connect(dbname: LINEAGE_DB)
    rows = db.exec("SELECT ordinal, hash, held_text FROM hecks_eras WHERE domain = 'Ledger'")
    expect(rows.ntuples).to eq(1)
    expect(rows[0]["ordinal"]).to eq("1")
    expect(rows[0]["hash"]).to be_nil
    expect(rows[0]["held_text"]).to eq(V1_SOURCE)
    db.close

    expect { check!(V1_SOURCE) }.not_to raise_error
  end

  # Every edit reaches the same generic wording: telling cosmetic from shape edits would need
  # boot to re-parse held era text, so EraTamper.refusal does not.
  it "refuses an edited hecks_eras row toward the generic wording — with the archive as recovery" do
    check!(V1_SOURCE)
    db = PG.connect(dbname: LINEAGE_DB)

    generic_wording = "cannot boot Ledger: the held text of era 1 was edited after it was frozen — " \
                      "held era texts are storage facts; restore the original text, or reset the data"

    db.exec_params("UPDATE hecks_eras SET held_text = $1 WHERE domain = 'Ledger' AND ordinal = 1", [V2_SOURCE])
    expect { check!(V1_SOURCE) }.to raise_error(Hecks::Runtime::WiringError, generic_wording)

    db.exec_params("UPDATE hecks_eras SET held_text = $1 WHERE domain = 'Ledger' AND ordinal = 1",
                   ["# a typo fixed\n#{V1_SOURCE}"])
    expect { check!(V1_SOURCE) }.to raise_error(Hecks::Runtime::WiringError, generic_wording)

    # unparseable edit — a misspelled DSL method mid-`Kernel.eval`
    unparseable = V1_SOURCE.sub("attribute :cost, Money", "atribute :cost, Money")
    db.exec_params("UPDATE hecks_eras SET held_text = $1 WHERE domain = 'Ledger' AND ordinal = 1", [unparseable])
    expect { check!(V1_SOURCE) }.to raise_error(Hecks::Runtime::WiringError, generic_wording)

    archived = db.exec("SELECT held_text FROM hecks_era_texts WHERE domain = 'Ledger' AND ordinal = 1")
    expect(archived.ntuples).to eq(1)
    expect(archived[0]["held_text"]).to eq(V1_SOURCE)
    db.exec_params("UPDATE hecks_eras SET held_text = $1 WHERE domain = 'Ledger' AND ordinal = 1",
                   [archived[0]["held_text"]])
    db.close
    expect { check!(V1_SOURCE) }.not_to raise_error
  end

  it "re-attesting an edited hecks_eras row re-freezes it, with the attestation on the record" do
    check!(V1_SOURCE)
    db = PG.connect(dbname: LINEAGE_DB)
    old_digest = db.exec("SELECT held_digest FROM hecks_eras WHERE domain = 'Ledger' AND ordinal = 1")[0]["held_digest"]
    db.exec_params("UPDATE hecks_eras SET held_text = $1 WHERE domain = 'Ledger' AND ordinal = 1", [V2_SOURCE])

    expect { check!(V1_SOURCE) }.to raise_error(Hecks::Runtime::WiringError, /edited after it was frozen/)

    lineage = Hecks::Adapters::PostgresEra::Lineage.new(db, "Ledger")
    fresh = lineage.reattest!(1)
    expect(fresh).to eq(Digest::SHA256.hexdigest(V2_SOURCE))

    attestation = db.exec("SELECT * FROM hecks_attestations WHERE domain = 'Ledger'")[0]
    expect(attestation["old_digest"]).to eq(old_digest)
    expect(attestation["new_digest"]).to eq(fresh)
    expect(attestation["attested_at"]).not_to be_nil
    db.close

    expect { check!(V2_SOURCE) }.not_to raise_error
  end

  it "refuses drift with no edge, naming both authoring tools" do
    check!(V1_SOURCE)
    expect { check!(V2_SOURCE) }.to raise_error(
      Hecks::Runtime::WiringError,
      "cannot boot Ledger: the shape changed (era 2) and no translation edge covers it — " \
      "run bin/scaffold_translation to write the edge, check it with bin/translation_audit, then boot again"
    )
  end

  it "refuses a stale edge whose target hash no longer matches the current shape" do
    check!(V1_SOURCE)
    from = label_of(V1_SOURCE)
    stale = edge_source(from: from, to: "000000")
    expect { check!(V2_SOURCE, translation_source: stale) }.to raise_error(
      Hecks::Runtime::WiringError, %r{the edge is stale; re-run bin/scaffold_translation}
    )
  end

  it "refuses a mechanical fork — two edges leaving one source shape" do
    check!(V1_SOURCE)
    from = label_of(V1_SOURCE)
    to = label_of(V2_SOURCE)
    forked = edge_source(from: from, to: to) + edge_source(from: from, to: "111111")
    expect { check!(V2_SOURCE, translation_source: forked) }.to raise_error(
      Hecks::Runtime::WiringError, /eras fork mechanically; keep one edge per source shape/
    )
  end

  it "refuses an edge that does not cover the whole diff, in EraGuard's own words" do
    check!(V1_SOURCE)
    from = label_of(V1_SOURCE)
    to = label_of(V2_SOURCE)
    partial = <<~RUBY
      Hecks.data_translation("Ledger", from: #{from.inspect}, to: #{to.inspect}) do
        aggregate("Account", was: "Acct") do
          rename :cost, to: :amount
          move "amount.currency", to: "denomination.code"
          convert "kind.label", to: "kind.label", values: { "biz" => "business" }
        end
      end
    RUBY
    expect { check!(V2_SOURCE, translation_source: partial) }.to raise_error(
      Hecks::Runtime::WiringError,
      /
        cannot\ boot\ Ledger::Account:\ its\ shape\ changed\ and\ :legacy_note\ is\ not\ explained\ by\ any
        \ rename,\ move,\ convert,\ retype,\ or\ drop
      /x
    )
  end

  # One mint checked from every angle (eras table, era-1 journal row, head, new partition);
  # splitting would re-pay the mint.
  # rubocop:disable-next RSpec/ExampleLength
  it "mints era 2 in one transaction and derives the head through the edge — old entries translated at " \
     "inclusion, never rewritten" do
    write_v1_record
    from = label_of(V1_SOURCE)
    to = label_of(V2_SOURCE)

    registry = check!(V2_SOURCE, translation_source: edge_source(from: from, to: to))

    db = PG.connect(dbname: LINEAGE_DB)
    eras = db.exec("SELECT ordinal, hash, label, watermark FROM hecks_eras WHERE domain = 'Ledger' ORDER BY ordinal")
    expect(eras.ntuples).to eq(2)
    expect(eras[0]["label"]).to eq(from)
    expect(eras[1]["label"]).to eq(to)
    expect(eras[1]["hash"]).to eq(hash_of(V2_SOURCE))
    expect(eras[1]["watermark"]).to eq("1")

    original = db.exec("SELECT era, aggregate, state FROM hecks_journal_ledger ORDER BY ordinal")
    expect(original.ntuples).to eq(1)
    expect(original[0]["era"]).to eq("1")
    expect(original[0]["aggregate"]).to eq("acct")
    expect(JSON.parse(original[0]["state"])["cost"]).to eq("cents" => 100, "currency" => "USD")

    adapter = adapter_for(registry, "Account")
    found = adapter.find("a1")
    expect(found.amount.to_h).to eq(cents: 100)
    expect(found.denomination.to_h).to eq(code: "USD")
    expect(found.kind.to_h).to eq(label: "business")
    expect(found.key?(:legacy_note)).to be(false)

    updated = Hecks::Runtime::Instance.new(
      aggregate: registry.bluebooks.values.first.aggregate("Account"), id: "a1",
      state: { amount: { "cents" => 250 }, kind: { "label" => "business" }, denomination: { "code" => "EUR" } }
    )
    adapter.save(updated)
    expect(adapter.find("a1").amount.to_h).to eq(cents: 250)

    partitions = db.exec("SELECT era, count(*) FROM hecks_journal_ledger GROUP BY era ORDER BY era")
    expect(partitions.map { |row| [row["era"], row["count"]] }).to eq([["1", "1"], ["2", "1"]])
    db.close
  end

  # A delete writes a tombstone row in the current era's snapshot: a bare DELETE would leave
  # nothing to outrank the ancestor's save row in the head view's DISTINCT ON union.
  it "deleting an era-migrated record does not resurrect the ancestor era's save row" do
    write_v1_record
    from = label_of(V1_SOURCE)
    to = label_of(V2_SOURCE)
    registry = check!(V2_SOURCE, translation_source: edge_source(from: from, to: to))

    adapter = adapter_for(registry, "Account")
    expect(adapter.find("a1")).not_to be_nil # sanity: the migrated record is there pre-delete

    adapter.delete("a1")

    expect(adapter.find("a1")).to be_nil
    expect(adapter.all.map(&:id)).not_to include("a1")
    expect(adapter.count).to eq(0)

    # a fresh boot's ensure_head_snapshot! backfill must not un-delete it either
    reopened = adapter_for(registry, "Account")
    expect(reopened.find("a1")).to be_nil

    db = PG.connect(dbname: LINEAGE_DB)
    expect(db.exec("SELECT count(*) FROM ledger_account_head WHERE id = 'a1'")[0]["count"]).to eq("0")
    # the tombstone is a real row that outranks the ancestor's save row
    tombstone = db.exec("SELECT operation, state FROM ledger_account_head_snapshot_2 WHERE id = 'a1'")
    expect(tombstone.ntuples).to eq(1)
    expect(tombstone[0]["operation"]).to eq("delete")
    expect(tombstone[0]["state"]).to be_nil
    db.close
  end

  it "an era-migrated record can be deleted and then re-saved, and the re-save wins" do
    write_v1_record
    from = label_of(V1_SOURCE)
    to = label_of(V2_SOURCE)
    registry = check!(V2_SOURCE, translation_source: edge_source(from: from, to: to))

    adapter = adapter_for(registry, "Account")
    adapter.delete("a1")
    expect(adapter.find("a1")).to be_nil

    revived = Hecks::Runtime::Instance.new(
      aggregate: registry.bluebooks.values.first.aggregate("Account"), id: "a1",
      state: { amount: { "cents" => 42 }, kind: { "label" => "business" }, denomination: { "code" => "USD" } }
    )
    adapter.save(revived)

    expect(adapter.find("a1").amount.to_h).to eq(cents: 42)
    expect(adapter.count).to eq(1)
  end

  it "a convert meeting an unmapped value refuses the whole mint — the era is never half-born" do
    write_v1_record(
      cost:        { "cents" => 5, "currency" => "USD" },
      kind:        { "label" => "mystery" },
      legacy_note: { "text" => "x" }
    )
    from = label_of(V1_SOURCE)
    to = label_of(V2_SOURCE)

    expect { check!(V2_SOURCE, translation_source: edge_source(from: from, to: to)) }.to raise_error(
      Hecks::Runtime::WiringError,
      /cannot translate kind.label: "mystery" has no mapping in its convert's values: table. Add "mystery" => \.\.\. to cover it/
    )

    db = PG.connect(dbname: LINEAGE_DB)
    expect(db.exec("SELECT count(*) FROM hecks_eras WHERE domain = 'Ledger'")[0]["count"]).to eq("1")
    db.close
  end

  # Targets the mechanism directly, since the pre-mint audit catches every DSL-level refusal
  # first. PG::Connection#transaction is a bare `BEGIN`/`COMMIT` without savepoints, so
  # ensure_head_snapshot! run mid-transaction must not commit it, or the `ROLLBACK` undoes nothing.
  it "ensure_head_snapshot! does not end an already-open transaction — a later rollback still undoes it" do
    check!(V1_SOURCE)
    registry = load_registry(V1_SOURCE)
    acct = registry.bluebooks.values.first.aggregate("Acct")

    db = PG.connect(dbname: LINEAGE_DB)
    lineage = Hecks::Adapters::PostgresEra::Lineage.new(db, "Ledger")

    db.exec("BEGIN")
    db.exec_params(
      "INSERT INTO hecks_eras (domain, ordinal, hash, label, held_text, watermark, held_digest, canon_form) " \
      "VALUES ('Ledger', 99, 'placeholder-hash', 'xxxxxx', 'placeholder', 1, 'placeholder-digest', 1)"
    )
    lineage.ensure_head_snapshot!(acct.storage_name, 99)
    # Stands in for mint_era!'s rescue: a later failure rolls the whole mint back.
    db.exec("ROLLBACK")
    db.close

    fresh = PG.connect(dbname: LINEAGE_DB)
    expect(fresh.exec("SELECT count(*) FROM hecks_eras WHERE domain = 'Ledger' AND ordinal = 99")[0]["count"]).to eq("0")
    expect(fresh.exec("SELECT to_regclass('ledger_acct_head_snapshot_99') IS NULL AS gone")[0]["gone"]).to eq("t")
    fresh.close
  end

  # A move destination that collides with an existing scalar (a reference_to field, a bare id)
  # must refuse by name instead of overwriting it; mirrors spec/translation_language_spec.rb.
  # The inline two-aggregate domain, real save and colliding edge pin the shadow-parse
  # regression, so the shape is not split up.
  # rubocop:disable-next RSpec/ExampleLength
  it "a move whose destination collides with an existing scalar refuses the mint by name, not silently" do
    # Bare `reference_to Team` (no `as:`) is deliberate: shadow_parse (era_guard.rb) must try a
    # normal parse first, or shadow mode's default mints `team_id` and breaks the edge lookup.
    collide_v1 = <<~BLUEBOOK
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
    collide_v2 = collide_v1.sub('aggregate "Acct"', 'aggregate "Account"')

    reg1 = check!(collide_v1)
    acct = reg1.bluebooks.values.first.aggregate("Acct")
    Hecks::Adapters::PostgresEra.new(aggregate: acct, settings: { database: LINEAGE_DB, domain: "Collide" })
                                .save(Hecks::Runtime::Instance.new(
                                        aggregate: acct, id: "a1",
                                        state: { amount: { "cents" => 500 }, kind: { "value" => "biz" }, team: "team-1" }
                                      ))

    from = label_of(collide_v1)
    to = label_of(collide_v2)
    edge = <<~RUBY
      Hecks.data_translation("Collide", from: #{from.inspect}, to: #{to.inspect}) do
        aggregate("Account", was: "Acct") do
          rename :team, to: :team_ref
          move "amount.cents", to: "team_ref.detail"
        end
      end
    RUBY

    expect { check!(collide_v2, translation_source: edge) }.to raise_error(
      Hecks::Runtime::WiringError,
      /cannot move amount\.cents to: team_ref\.detail: team_ref already holds "team-1", not a value this can nest under/
    )
  end

  # A post-cut row in a superseded era: frozen tail, old-world read, head blindness and
  # diverged_count are all checked against the same inserted row.
  # rubocop:disable-next RSpec/ExampleLength
  it "however a post-cut row lands in a superseded era, the reconciliation machinery does not lose it or leak it" do
    # The row is inserted as the owner, standing in for a writer racing a live mint (RLS is
    # checked at statement time, not at commit); the fence specs show an ordinary role cannot.
    # Under test is what follows: the frozen tail, diverged_count and merge_tail.
    write_v1_record
    from = label_of(V1_SOURCE)
    to = label_of(V2_SOURCE)
    check!(V2_SOURCE, translation_source: edge_source(from: from, to: to))

    old_registry = check!(V1_SOURCE)
    expect(old_registry.resolved_eras["Ledger"]).to eq(1)

    db = PG.connect(dbname: LINEAGE_DB)
    state = JSON.generate(cost: { "cents" => 5, "currency" => "USD" }, kind: { "label" => "biz" },
                          legacy_note: { "text" => "late" })
    ordinal = db.exec_params(
      "INSERT INTO hecks_journal_ledger (era, aggregate, aggregate_id, operation, state) " \
      "VALUES (1, 'acct', $1, 'save', $2) RETURNING ordinal",
      ["a9", state]
    )[0]["ordinal"]
    # ...plus the era-1 snapshot table that append would write; old_world.find reads it verbatim.
    db.exec_params(
      "INSERT INTO ledger_acct_head_snapshot_1 (id, ordinal, state) VALUES ($1, $2, $3)",
      ["a9", ordinal, state]
    )

    eras_of_a9 = db.exec("SELECT era FROM hecks_journal_ledger WHERE aggregate_id = 'a9'").map { |row| row["era"] }
    expect(eras_of_a9).to eq(["1"])
    # ...an era-1 checkout still sees it, under the old storage name...
    old_world = Hecks::Adapters::PostgresEra.new(
      aggregate: old_registry.bluebooks.values.first.aggregate("Acct"),
      settings:  { database: owner_url, domain: "Ledger", era: 1 }
    )
    expect(old_world.find("a9").cost.to_h).to eq(cents: 5, currency: "USD")
    # ...the new head does not (the watermark is baked into the matview)...
    new_head = db.exec("SELECT count(*) FROM ledger_account_head WHERE id = 'a9'")[0]["count"]
    expect(new_head).to eq("0")
    lineage = Hecks::Adapters::PostgresEra::Lineage.new(db, "Ledger")
    expect(lineage.diverged_count(1)).to eq(1)
    db.close
  end

  # One concurrency proof: the seeded ancestor tail, a background writer and a live mint race.
  # rubocop:disable-next RSpec/ExampleLength
  it "an ordinary writer is never blocked by a mint — advance_era!'s AccessExclusiveLock is held for the " \
     "commit, not the matview build" do
    write_v1_record
    from = label_of(V1_SOURCE)
    to = label_of(V2_SOURCE)

    # a real ancestor tail makes the matview build slow enough to widen any lock window
    db = PG.connect(dbname: LINEAGE_DB)
    3_000.times do |i|
      db.exec_params(
        "INSERT INTO hecks_journal_ledger (era, aggregate, aggregate_id, operation, state) VALUES (1, 'acct', $1, 'save', $2)",
        ["bulk-#{i}",
         JSON.generate(cost: { "cents" => i, "currency" => "USD" }, kind: { "label" => "biz" }, legacy_note: { "text" => "x" })]
      )
    end
    db.close

    # Lock contention means the reordering failed; an RLS refusal after the mint commits is
    # expected. Only the first kind counts as a failure.
    stop = false
    ok = 0
    lock_blocked = 0
    fence_refused = 0
    writer = Thread.new do
      w = PG.connect(owner_url)
      w.exec("SET lock_timeout = '500ms'")
      # An aggregate name the bluebook never declares, so the mint's audit never sees these
      # rows; the partition-level locks are still exercised.
      until stop
        begin
          w.exec("INSERT INTO hecks_journal_ledger (era, aggregate, aggregate_id, operation, state) " \
                 "VALUES (1, 'unrelated_probe', 'live', 'save', '{}'::jsonb)")
          ok += 1
        rescue PG::Error => e
          if e.message =~ /lock timeout|canceling statement/i
            lock_blocked += 1
          else
            fence_refused += 1
          end
        end
      end
      w.close
    end
    sleep 0.05 # let the writer get a few writes in before the mint starts

    check!(V2_SOURCE, translation_source: edge_source(from: from, to: to))

    stop = true
    writer.join

    expect(ok).to be > 0
    expect(lock_blocked).to eq(0)
  end

  def fork_worlds
    write_v1_record
    from = label_of(V1_SOURCE)
    to = label_of(V2_SOURCE)
    edge = edge_source(from: from, to: to)
    new_registry = check!(V2_SOURCE, translation_source: edge)

    new_world = Hecks::Adapters::PostgresEra.new(
      aggregate: new_registry.bluebooks.values.first.aggregate("Account"),
      settings:  { database: LINEAGE_DB, domain: "Ledger", era: 2 }
    )
    new_world.save(Hecks::Runtime::Instance.new(
                     aggregate: new_registry.bluebooks.values.first.aggregate("Account"), id: "a1",
                     state: { amount: { "cents" => 999 }, kind: { "label" => "business" },
                              denomination: { "code" => "USD" }, status: "open" }
                   ))

    old_registry = check!(V1_SOURCE)
    acct = old_registry.bluebooks.values.first.aggregate("Acct")
    old_world = Hecks::Adapters::PostgresEra.new(
      aggregate: acct, settings: { database: LINEAGE_DB, domain: "Ledger", era: 1 }
    )
    old_world.save(Hecks::Runtime::Instance.new(
                     aggregate: acct, id: "a1",
                     state: { cost: { "cents" => 111, "currency" => "USD" }, kind: { "label" => "biz" },
                              legacy_note: { "text" => "old edit" } }
                   ))
    old_world.save(Hecks::Runtime::Instance.new(
                     aggregate: acct, id: "a9",
                     state: { cost: { "cents" => 5, "currency" => "EUR" }, kind: { "label" => "pers" },
                              legacy_note: { "text" => "late" } }
                   ))
    [new_registry, edge]
  end

  # One sequential scenario: refuse without a winner, then merge the same forked state with one.
  # rubocop:disable-next RSpec/ExampleLength
  it "tail-merge: refuses both-worlds conflicts by name, then interleaves the declared winner append-only" do
    new_registry, = fork_worlds

    expect do
      Hecks::Adapters::PostgresEra::LineageManager.merge!(
        registry: new_registry, bluebook: new_registry.bluebooks.values.first, settings: { database: LINEAGE_DB }
      )
    end.to raise_error(
      Hecks::Runtime::WiringError,
      "cannot merge the tail of Ledger: touched by both worlds since the cut — account#a1. " \
      "Name each winner (--winner <id>=old or --winner <id>=new), then run bin/merge_tail again. " \
      "A winner takes the WHOLE record — the aggregate is the consistency boundary, so the " \
      "loser's edits are discarded even where they touched different attributes"
    )

    db = PG.connect(dbname: LINEAGE_DB)
    ancestor_before = db.exec("SELECT ordinal, state FROM hecks_journal_ledger_era_1 ORDER BY ordinal").values

    Hecks::Adapters::PostgresEra::LineageManager.merge!(
      registry: new_registry, bluebook: new_registry.bluebooks.values.first,
      settings: { database: LINEAGE_DB }, winners: { "a1" => "new" }
    )

    head = db.exec("SELECT id, state FROM ledger_account_head ORDER BY id").to_h { |row| [row["id"], JSON.parse(row["state"])] }
    expect(head["a9"]["amount"]).to eq("cents" => 5)
    expect(head["a9"]["denomination"]).to eq("code" => "EUR")
    expect(head["a9"]["kind"]).to eq("label" => "personal")
    expect(head["a1"]["amount"]).to eq("cents" => 999)

    lineage = Hecks::Adapters::PostgresEra::Lineage.new(db, "Ledger")
    expect(lineage.diverged_count(1)).to eq(0)

    ancestor_after = db.exec("SELECT ordinal, state FROM hecks_journal_ledger_era_1 ORDER BY ordinal").values
    expect(ancestor_after).to eq(ancestor_before)
    db.close
  end

  it "refuses an identity-path change as a re-keying, not a translation" do
    rekeyed = V2_SOURCE.sub("identified_by :kind", "identified_by :amount")
    write_v1_record
    from = label_of(V1_SOURCE)
    to = label_of(rekeyed)

    expect { check!(rekeyed, translation_source: edge_source(from: from, to: to)) }.to raise_error(
      Hecks::Runtime::WiringError,
      "cannot mint an era for Ledger::Account: its identity path changed (kind.label → amount.cents), and that is " \
      "a re-keying, not a translation — stored ids were minted under kind.label, and no rule declares rows " \
      "the same entity under a new key. Keep the identity path, declare a rekey rule, or migrate the " \
      "data explicitly"
    )
  end

  it "a concurrent minter loses the advisory-lock race gracefully and adopts the era the winner minted" do
    write_v1_record
    from = label_of(V1_SOURCE)
    to = label_of(V2_SOURCE)
    edge = edge_source(from: from, to: to)

    check!(V2_SOURCE, translation_source: edge)

    # the "loser": a second boot of the same drifted shape finds the era
    # already born and proceeds into it — no error, no duplicate row
    loser = check!(V2_SOURCE, translation_source: edge)
    expect(loser.resolved_eras["Ledger"]).to eq(2)

    db = PG.connect(dbname: LINEAGE_DB)
    expect(db.exec("SELECT count(*) FROM hecks_eras WHERE domain = 'Ledger'")[0]["count"]).to eq("2")

    # and the raw race inside the lock: a direct second mint of the same
    # ordinal re-checks under the lock and stands down
    lineage = Hecks::Adapters::PostgresEra::Lineage.new(db, "Ledger")
    stood_down = lineage.mint_era!(
      ordinal: 2, hash: "x", label: "x", held_text: "x",
      aggregates: [], edges: []
    )
    expect(stood_down).to be(false)
    expect(db.exec("SELECT label FROM hecks_eras WHERE domain = 'Ledger' AND ordinal = 2")[0]["label"]).to eq(to)
    db.close
  end

  it "tail-merge: winner=old restores the old world's translated state as the newest row" do
    new_registry, = fork_worlds

    Hecks::Adapters::PostgresEra::LineageManager.merge!(
      registry: new_registry, bluebook: new_registry.bluebooks.values.first,
      settings: { database: LINEAGE_DB }, winners: { "a1" => "old" }
    )

    db = PG.connect(dbname: LINEAGE_DB)
    a1 = JSON.parse(db.exec("SELECT state FROM ledger_account_head WHERE id = 'a1'")[0]["state"])
    db.close
    expect(a1["amount"]).to eq("cents" => 111)
    expect(a1["denomination"]).to eq("code" => "USD")
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

  # One edge's lifecycle: refuse without approval, approve, invalidate by advancing the
  # journal, re-approve, mint, then compare the compiled SQL to the in-process reference.
  # rubocop:disable-next RSpec/ExampleLength
  it "evaluates a compute rule exclusively inside the compiled matview — its SQL is its only implementation" do
    registry = load_registry(PRICING_V1)
    Hecks::Adapters::PostgresEra::LineageManager.check!(
      registry: registry, bluebook: registry.bluebooks.values.first,
      current_text: PRICING_V1, settings: { database: owner_url }
    )
    quote = registry.bluebooks.values.first.aggregate("Quote")
    adapter = Hecks::Adapters::PostgresEra.new(aggregate: quote, settings: { database: LINEAGE_DB, domain: "Pricing" })
    adapter.save(Hecks::Runtime::Instance.new(aggregate: quote, id: "q1", state: { price_cents: { "value" => 1250 } }))

    from = label_of(PRICING_V1)
    to = label_of(PRICING_V2)
    compute_edge = <<~RUBY
      Hecks.data_translation("Pricing", from: #{from.inspect}, to: #{to.inspect}) do
        aggregate("Quote") do
          compute "price_cents", to: "price_dollars",
                  sql: "jsonb_build_object('value', (price_cents::jsonb ->> 'value')::numeric / 100)"
        end
      end
    RUBY

    drifted = load_registry(PRICING_V2, translation_source: compute_edge)

    # a compute's only verification is the audit's human-approved sample
    # — without the approval token the mint refuses, non-interactively
    expect do
      Hecks::Adapters::PostgresEra::LineageManager.check!(
        registry: drifted, bluebook: drifted.bluebooks.values.first,
        current_text: PRICING_V2, settings: { database: owner_url }
      )
    end.to raise_error(
      Hecks::Runtime::WiringError,
      "cannot mint era 2 of Pricing: this edge carries a compute or rekey rule, and the audit's " \
      "human-approved sample is its only verification — run bin/translation_audit with --approve, then boot again"
    )

    # the approval binds to the edge's content and the journal's
    # high-water ordinal at review time, in the database itself
    db = PG.connect(dbname: LINEAGE_DB)
    pricing_lineage = Hecks::Adapters::PostgresEra::Lineage.new(db, "Pricing")
    pricing_lineage.record_approval!(
      from: from, to: to,
      edge_digest: Hecks::Translation::Audit.edge_digest(drifted.translations.first)
    )

    adapter.save(Hecks::Runtime::Instance.new(aggregate: quote, id: "q2", state: { price_cents: { "value" => 300 } }))
    expect do
      Hecks::Adapters::PostgresEra::LineageManager.check!(
        registry: drifted, bluebook: drifted.bluebooks.values.first,
        current_text: PRICING_V2, settings: { database: owner_url }
      )
    end.to raise_error(
      Hecks::Runtime::WiringError,
      %r{
        the\ journal\ advanced\ past\ the\ approved\ review\ \(ordinal\ 1\ reviewed,\ 2\ now\)\ —\ the\ samples
        \ a\ human\ approved\ no\ longer\ cover\ the\ data;\ re-run\ bin/translation_audit\ with\ --approve
      }x
    )

    pricing_lineage.record_approval!(
      from: from, to: to,
      edge_digest: Hecks::Translation::Audit.edge_digest(drifted.translations.first)
    )
    db.close

    Hecks::Adapters::PostgresEra::LineageManager.check!(
      registry: drifted, bluebook: drifted.bluebooks.values.first,
      current_text: PRICING_V2, settings: { database: owner_url }
    )

    db = PG.connect(dbname: LINEAGE_DB)
    compiled = JSON.parse(db.exec("SELECT state FROM pricing_quote_lineage_2_#{to} WHERE aggregate_id = 'q1'")[0]["state"])
    db.close
    expect(compiled).to eq("price_dollars" => { "value" => 12.5 }, "sku" => { "value" => "q1" })

    # ...and the in-process reference transform deliberately did not —
    # compute is exempt from the equivalence gate; there is nothing
    # in-process to hold it against.
    declared = drifted.translations.first.for_aggregate("Quote")
    rules = Hecks::Ports::Persistence::Lineage.from_declared(declared, "Quote")
    entry = Hecks::Ports::Persistence::Entry.new(operation: "save", id: "q1", state: { price_cents: { "value" => 1250 } })
    expect(rules.translate(entry).state).to eq(price_cents: { "value" => 1250 })

    v2_quote = drifted.bluebooks.values.first.aggregate("Quote")
    head = Hecks::Adapters::PostgresEra.new(aggregate: v2_quote, settings: { database: LINEAGE_DB, domain: "Pricing" })
    expect(head.find("q1").price_dollars.to_h).to eq(value: 12.5)
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

  # Same approval lifecycle as the compute example: the record resolves under its new id
  # while the raw journal stays keyed to the old one.
  # rubocop:disable-next RSpec/ExampleLength
  it "mints an era that rekeys an aggregate's identity, with an approved rekey rule" do
    registry = load_registry(ROSTER_V1)
    Hecks::Adapters::PostgresEra::LineageManager.check!(
      registry: registry, bluebook: registry.bluebooks.values.first,
      current_text: ROSTER_V1, settings: { database: owner_url }
    )
    person = registry.bluebooks.values.first.aggregate("Person")
    adapter = Hecks::Adapters::PostgresEra.new(aggregate: person, settings: { database: LINEAGE_DB, domain: "Roster" })
    adapter.save(Hecks::Runtime::Instance.new(
                   aggregate: person, id: "Chris Young", state: { name:  { "value" => "Chris Young" },
                                                                  title: { "value" => "CEO" } }
                 ))

    from = label_of(ROSTER_V1)
    to = label_of(ROSTER_V2)
    rekey_edge = <<~RUBY
      Hecks.data_translation("Roster", from: #{from.inspect}, to: #{to.inspect}) do
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

    drifted = load_registry(ROSTER_V2, translation_source: rekey_edge)

    # a rekey's only verification is the audit's human-approved sample,
    # same as compute — the mint refuses non-interactively without it
    expect do
      Hecks::Adapters::PostgresEra::LineageManager.check!(
        registry: drifted, bluebook: drifted.bluebooks.values.first,
        current_text: ROSTER_V2, settings: { database: owner_url }
      )
    end.to raise_error(Hecks::Runtime::WiringError, /this edge carries a compute or rekey rule/)

    db = PG.connect(dbname: LINEAGE_DB)
    roster_lineage = Hecks::Adapters::PostgresEra::Lineage.new(db, "Roster")
    roster_lineage.record_approval!(
      from: from, to: to,
      edge_digest: Hecks::Translation::Audit.edge_digest(drifted.translations.first)
    )
    db.close

    Hecks::Adapters::PostgresEra::LineageManager.check!(
      registry: drifted, bluebook: drifted.bluebooks.values.first,
      current_text: ROSTER_V2, settings: { database: owner_url }
    )

    # the compiled matview resolves the record under its new id, and
    # only its new id — the raw journal row is untouched (still keyed
    # "Chris Young"), but nothing reads it directly
    db = PG.connect(dbname: LINEAGE_DB)
    under_new_id = db.exec("SELECT state FROM roster_person_lineage_2_#{to} WHERE aggregate_id = 'chris@example.com'")
    under_old_id = db.exec("SELECT state FROM roster_person_lineage_2_#{to} WHERE aggregate_id = 'Chris Young'")
    raw_journal = db.exec("SELECT aggregate_id FROM hecks_journal_roster WHERE aggregate_id = 'Chris Young'")
    db.close

    expect(under_new_id.ntuples).to eq(1)
    expect(under_old_id.ntuples).to eq(0)
    expect(raw_journal.ntuples).to eq(1) # the immutable journal never rewrites

    v2_person = drifted.bluebooks.values.first.aggregate("Person")
    head = Hecks::Adapters::PostgresEra.new(aggregate: v2_person, settings: { database: LINEAGE_DB, domain: "Roster" })
    found = head.find("chris@example.com")
    expect(found.name.to_h).to eq(value: "Chris Young")
    expect(found.title.to_h).to eq(value: "CEO")
    expect(head.find("Chris Young")).to be_nil
  end

  # One fenced role checked from every angle against the same mint; each only means something
  # read against that one fence.
  # rubocop:disable-next RSpec/ExampleLength
  it "fences a deployment's app role at the era its checkout speaks — and the fence is written through, " \
     "not read off the catalog" do
    reset_app_role!
    write_v1_record
    from = label_of(V1_SOURCE)
    to = label_of(V2_SOURCE)
    check!(V2_SOURCE, translation_source: edge_source(from: from, to: to), role: LINEAGE_ROLE)

    journal = "hecks_journal_ledger"

    # The fenced role must still boot; ensure_base!'s ALTER TABLE and REVOKE are owner-only.
    app = PG.connect(dbname: LINEAGE_DB, user: LINEAGE_ROLE)
    expect { Hecks::Adapters::PostgresEra::Lineage.new(app, "Ledger").ensure_base! }.not_to raise_error
    app.close

    append = lambda do |era|
      as_app_role(
        "INSERT INTO #{journal} (era, aggregate, aggregate_id, operation, state) " \
        "VALUES (#{era}, 'account', 'fenced-#{era}', 'save', '{}'::jsonb)"
      )
    end

    expect(append.call(2)).to eq(:allowed)

    # A per-partition GRANT cannot express this: Postgres checks INSERT on the partitioned
    # parent for a routed insert and never consults the partition.
    expect(append.call(1)).to match(/row-level security policy/i)

    # a partition is no back door: the role is granted on the parent only
    expect(
      as_app_role("INSERT INTO #{journal}_era_1 (era, aggregate, aggregate_id, operation, state) " \
                  "VALUES (1, 'acct', 'leaf', 'save', '{}'::jsonb)")
    ).to match(/permission denied/i)

    expect(as_app_role("UPDATE #{journal} SET operation = 'delete'")).to match(/permission denied|row-level security/i)
    expect(as_app_role("DELETE FROM #{journal}")).to match(/permission denied|row-level security/i)

    # the owner is not fenced — mint and merge must reach every era
    owner = PG.connect(dbname: LINEAGE_DB)
    expect do
      owner.exec("INSERT INTO #{journal} (era, aggregate, aggregate_id, operation, state) " \
                 "VALUES (1, 'acct', 'owner-write', 'save', '{}'::jsonb)")
    end.not_to raise_error
    owner.close
  end

  # Adversarial routing techniques against a naive check: a CTE, a function body and copy.
  # Postgres refuses copy from outright once RLS is enabled on the target; do not relax force
  # ROW LEVEL SECURITY without knowing that. One shared setup keeps the three cases together.
  # rubocop:disable-next RSpec/ExampleLength
  it "a fenced role cannot route an era-1 write around the fence through a CTE, a function body, or COPY" do
    reset_app_role!
    write_v1_record
    from = label_of(V1_SOURCE)
    to = label_of(V2_SOURCE)
    check!(V2_SOURCE, translation_source: edge_source(from: from, to: to), role: LINEAGE_ROLE)

    journal = "hecks_journal_ledger"

    expect(
      as_app_role(
        "WITH x AS (INSERT INTO #{journal} (era, aggregate, aggregate_id, operation, state) " \
        "VALUES (1, 'account', 'cte', 'save', '{}'::jsonb) RETURNING 1) SELECT * FROM x"
      )
    ).to match(/row-level security/i)

    expect(
      as_app_role(
        "DO $$ BEGIN INSERT INTO #{journal} (era, aggregate, aggregate_id, operation, state) " \
        "VALUES (1, 'account', 'do-block', 'save', '{}'::jsonb); END $$"
      )
    ).to match(/row-level security/i)

    db = PG.connect(dbname: LINEAGE_DB, user: LINEAGE_ROLE)
    begin
      db.exec("COPY #{journal} (era, aggregate, aggregate_id, operation, state) FROM STDIN")
      raise "COPY should not even be attempted under RLS"
    rescue PG::Error => e
      expect(e.message).to match(/COPY FROM not supported with row-level security/i)
    ensure
      db&.close
    end
  end

  # A mint-shaped transaction is held open at the partition-attach point, the lock is probed
  # by name, then a concurrent write must go through.
  # rubocop:disable-next RSpec/ExampleLength
  it "an old checkout keeps writing its own era THROUGH a mint — the fork survives the window, it does not merely bracket it" do
    write_v1_record
    l1 = label_of(V1_SOURCE)
    l2 = label_of(V2_SOURCE)
    check!(V2_SOURCE, translation_source: edge_source(from: l1, to: l2))
    label_of(V3_SOURCE)

    # Hold a mint-shaped transaction open with the next era's partition attached, uncommitted.
    blocker = PG.connect(dbname: LINEAGE_DB)
    blocker.exec("BEGIN")
    Hecks::Adapters::PostgresEra::Lineage.new(blocker, "Ledger").ensure_partition!(3)

    # the lock that attach took, named — ShareUpdateExclusive conflicts
    # with neither reads nor inserts; AccessExclusive (what
    # CREATE ... PARTITION OF takes) conflicts with both
    probe = PG.connect(dbname: LINEAGE_DB)
    mode = probe.exec_params(
      "SELECT l.mode FROM pg_locks l JOIN pg_class c ON c.oid = l.relation " \
      "WHERE c.relname = $1 AND l.mode LIKE '%Exclusive%' ORDER BY l.mode LIMIT 1",
      ["hecks_journal_ledger"]
    )[0]&.fetch("mode")
    expect(mode).to eq("ShareUpdateExclusiveLock")

    writer = PG.connect(dbname: LINEAGE_DB)
    writer.exec("SET lock_timeout = '2s'")
    write = lambda do
      writer.exec(
        "INSERT INTO hecks_journal_ledger (era, aggregate, aggregate_id, operation, state) " \
        "VALUES (2, 'account', 'during-mint', 'save', '{}'::jsonb)"
      )
      :allowed
    rescue PG::Error => e
      e.message.strip
    end

    expect(write.call).to eq(:allowed)

    blocker.exec("ROLLBACK")
    blocker.close
    probe.close
    writer.close
  end

  # append holds pg_advisory_xact_lock(hashtext('hecks_ordinal:' || domain)) for its whole
  # transaction, a different key from the mint/merge lock. Holding it by hand must block a save.
  it "serializes concurrent plain writes against EACH OTHER — ordinal order can no longer diverge from commit order" do
    registry = check!(V1_SOURCE)
    adapter  = adapter_for(registry, "Acct")

    holder = PG.connect(dbname: LINEAGE_DB)
    holder.exec("BEGIN")
    holder.exec_params("SELECT pg_advisory_xact_lock(hashtext('hecks_ordinal:' || $1))", ["Ledger"])

    instance = Hecks::Runtime::Instance.new(
      aggregate: registry.bluebooks.values.first.aggregate("Acct"), id: "a2",
      state: { cost: { "cents" => 1, "currency" => "USD" }, kind: { "label" => "biz" }, legacy_note: { "text" => "x" } }
    )
    blocked = Thread.new { adapter.save(instance) }

    sleep 0.3
    expect(blocked).to be_alive # still waiting on the lock ; the write has not happened

    holder.exec("COMMIT")
    blocked.join(2)
    expect(blocked).not_to be_alive # released the instant the lock was — not before

    row = PG.connect(dbname: LINEAGE_DB).exec_params(
      "SELECT ordinal FROM hecks_journal_ledger WHERE aggregate_id = 'a2'"
    )[0]
    expect(row).not_to be_nil
    holder.close
  end

  it "a role rebooting into its OWN now-superseded era cannot write it — nothing about that boot may " \
     "reopen the schema a mint already closed" do
    reset_app_role!
    check!(V1_SOURCE, role: LINEAGE_ROLE)
    write_v1_record

    from = label_of(V1_SOURCE)
    to = label_of(V2_SOURCE)
    # a plain owner mint, no role at all
    check!(V2_SOURCE, translation_source: edge_source(from: from, to: to))

    # the same role reboots and correctly recognizes itself as
    # superseded (the "matched" branch) — nothing about its own
    # settings changed; the schema moved out from under it
    check!(V1_SOURCE, role: LINEAGE_ROLE)

    expect(
      as_app_role("INSERT INTO hecks_journal_ledger (era, aggregate, aggregate_id, operation, state) " \
                  "VALUES (1, 'account', 'after-reboot', 'save', '{}'::jsonb)")
    ).to match(/row-level security/i)
  end

  # Postgres exempts a superuser or BYPASSRLS role from every policy, force included, so boot
  # checks pg_roles and refuses by default; allow_superuser boots anyway and warns.
  # The ambient connection is a superuser locally and on CI (`PGUSER` is postgres); the two boot
  # examples skip when it is not.
  def ambient_role
    db = PG.connect(dbname: LINEAGE_DB)
    row = db.exec(
      "SELECT rolname, (rolsuper OR rolbypassrls) AS exempt FROM pg_roles WHERE rolname = current_user"
    )[0]
    db.close
    row
  end

  def check_as_ambient!(source, **extra_settings)
    registry = load_registry(source)
    Hecks::Adapters::PostgresEra::LineageManager.check!(
      registry: registry, bluebook: registry.bluebooks.values.first, current_text: source,
      settings: { database: LINEAGE_DB }.merge(extra_settings)
    )
    registry
  end

  it "refuses to boot over a superuser connection by default — the era write-fence is void for it, and says so" do
    ambient = ambient_role
    skip "the ambient Postgres role #{ambient['rolname']} is neither a superuser nor BYPASSRLS here" if ambient["exempt"] != "t"

    refusal = Regexp.new(
      "\\A#{Regexp.escape("cannot boot Ledger: PostgresEra's era write-fence is row-level security, and this " \
                          "connection's role #{ambient['rolname'].inspect} is ")}(a superuser|granted BYPASSRLS).*" \
      "#{Regexp.escape('Connect as an ordinary role instead')}.*" \
      "#{Regexp.escape('or declare `allow_superuser true` in the same persisted_by block')}",
      Regexp::MULTILINE
    )
    expect { check_as_ambient!(V1_SOURCE) }.to raise_error(Hecks::Runtime::WiringError, refusal)

    # refused before provisioning anything — a refused boot holds no era
    db = PG.connect(dbname: LINEAGE_DB)
    expect(db.exec("SELECT to_regclass('hecks_eras') IS NULL AS absent")[0]["absent"]).to eq("t")
    db.close
  end

  it "boots over a superuser connection under allow_superuser — and says the fence is void, every boot" do
    ambient = ambient_role
    skip "the ambient Postgres role #{ambient['rolname']} is neither a superuser nor BYPASSRLS here" if ambient["exempt"] != "t"

    void = Regexp.new(
      "#{Regexp.escape("[hecks] Ledger: booting PostgresEra as #{ambient['rolname'].inspect}, ")}.*" \
      "#{Regexp.escape('under allow_superuser — the era write-fence is void for this connection')}"
    )
    expect { check_as_ambient!(V1_SOURCE, allow_superuser: true) }.to output(void).to_stderr
    # the string spelling opts in too, and a quiet reboot warns again —
    # the fence is just as void the second time
    expect { check_as_ambient!(V1_SOURCE, "allow_superuser" => true) }.to output(void).to_stderr
    # a stored `false` is a real answer, not an absent key — still refused
    expect { check_as_ambient!(V1_SOURCE, allow_superuser: false, "allow_superuser" => true) }
      .to raise_error(Hecks::Runtime::WiringError, /era write-fence is row-level security/)

    db = PG.connect(dbname: LINEAGE_DB)
    expect(db.exec("SELECT count(*) FROM hecks_eras WHERE domain = 'Ledger'")[0]["count"]).to eq("1")
    db.close
  end

  # Proven as the owner, so the refusal must come from the adapter (WiringError before any
  # INSERT), not from the RLS policy. One old checkout is checked from every side at once.
  # rubocop:disable-next RSpec/ExampleLength
  it "a held-but-superseded checkout refuses its own writes in-process, naming the newer era — while its reads still work" do
    write_v1_record
    from = label_of(V1_SOURCE)
    to = label_of(V2_SOURCE)
    check!(V2_SOURCE, translation_source: edge_source(from: from, to: to))

    # the matched branch: an old checkout boots, and knows it is stale
    old_registry = check!(V1_SOURCE)
    expect(old_registry.resolved_eras["Ledger"]).to eq(1)
    expect(old_registry.superseded_eras["Ledger"]).to eq(2)
    # a current-era boot carries no such mark
    current = check!(V2_SOURCE, translation_source: edge_source(from: from, to: to))
    expect(current.resolved_eras["Ledger"]).to eq(2)
    expect(current.superseded_eras["Ledger"]).to be_nil

    # exactly the settings RepositoryFactory.build merges in for that boot
    acct = old_registry.bluebooks.values.first.aggregate("Acct")
    old_world = Hecks::Adapters::PostgresEra.new(
      aggregate: acct,
      settings:  { database: owner_url, domain: "Ledger",
                   era: old_registry.resolved_eras["Ledger"], superseded_by: old_registry.superseded_eras["Ledger"] }
    )
    refusal = "cannot write acct for Ledger: this checkout booted era 1, which era 2 has superseded — its shape " \
              "was replaced by a mint, and a write here would land in a partition no newer head reads. Reads " \
              "still work; pull the current bluebook and reboot to write again."
    late_state = { cost: { "cents" => 5, "currency" => "USD" }, kind: { "label" => "biz" }, legacy_note: { "text" => "late" } }
    expect { old_world.save(Hecks::Runtime::Instance.new(aggregate: acct, id: "a9", state: late_state)) }
      .to raise_error(Hecks::Runtime::WiringError, refusal)
    expect { old_world.atomic_put(Hecks::Ports::Persistence::Entry.new(operation: "save", id: "a9", state: late_state)) }
      .to raise_error(Hecks::Runtime::WiringError, refusal)
    expect { old_world.delete("a1") }.to raise_error(Hecks::Runtime::WiringError, refusal)

    expect(old_world.find("a1").cost.to_h).to eq(cents: 100, currency: "USD")
    expect(old_world.find("a9")).to be_nil
    expect(old_world.count).to eq(1)

    db = PG.connect(dbname: LINEAGE_DB)
    expect(Hecks::Adapters::PostgresEra::Lineage.new(db, "Ledger").diverged_count(1)).to eq(0)
    db.close
  end

  # One shared pair of roles and one mint checked from four angles; splitting would lose the
  # claim that the outcome does not depend on which role is asking.
  # rubocop:disable-next RSpec/ExampleLength
  it "the fence is a fact about the ERA, not the role — a mint by one role cuts EVERY role off the schema it just replaced" do
    old_role = "#{LINEAGE_ROLE}_old"
    new_role = "#{LINEAGE_ROLE}_new"
    admin = PG.connect(dbname: "postgres")
    [old_role, new_role].each do |role|
      scrub = PG.connect(dbname: LINEAGE_DB)
      begin
        scrub.exec("DROP OWNED BY #{role}")
      rescue PG::Error # rubocop:disable Lint/SuppressedException
      end
      scrub.close
      admin.exec("DROP ROLE IF EXISTS #{role}")
      admin.exec("CREATE ROLE #{role} LOGIN")
    end
    admin.close
    grants = PG.connect(dbname: LINEAGE_DB)
    [old_role, new_role].each do |role|
      grants.exec("GRANT CONNECT ON DATABASE #{LINEAGE_DB} TO #{role}")
      grants.exec("GRANT USAGE ON SCHEMA public TO #{role}")
    end
    grants.close

    check!(V1_SOURCE, role: old_role)
    write_v1_record

    writes = lambda do |role, era|
      db = PG.connect(dbname: LINEAGE_DB, user: role)
      db.exec("INSERT INTO hecks_journal_ledger (era, aggregate, aggregate_id, operation, state) " \
              "VALUES (#{era}, 'account', 'by-#{role}', 'save', '{}'::jsonb)")
      :allowed
    rescue PG::Error => e
      e.message.strip
    ensure
      db&.close
    end

    expect(writes.call(old_role, 1)).to eq(:allowed)

    from = label_of(V1_SOURCE)
    to = label_of(V2_SOURCE)
    check!(V2_SOURCE, translation_source: edge_source(from: from, to: to), role: new_role)

    expect(writes.call(new_role, 2)).to eq(:allowed)

    # ...and so does the old role: any role granted INSERT may write whatever era is current.
    expect(writes.call(old_role, 2)).to eq(:allowed)

    # no role may write era 1 once era 2 has materialized
    expect(writes.call(old_role, 1)).to match(/row-level security/i)
    expect(writes.call(new_role, 1)).to match(/row-level security/i)
  end

  # The layered build (reading era 2's matview) and a from-scratch full build must agree row
  # for row; both run against one mint through era 3.
  # rubocop:disable-next RSpec/ExampleLength
  it "builds era 3 from era 2's matview, not from raw history — and the layered answer equals the full one" do
    write_v1_record
    l1 = label_of(V1_SOURCE)
    l2 = label_of(V2_SOURCE)
    l3 = label_of(V3_SOURCE)
    check!(V2_SOURCE, translation_source: edge_source(from: l1, to: l2))

    registry = load_registry(V2_SOURCE)
    account = registry.bluebooks.values.first.aggregate("Account")
    adapter = Hecks::Adapters::PostgresEra.new(aggregate: account, settings: { database: LINEAGE_DB, domain: "Ledger" })
    adapter.save(Hecks::Runtime::Instance.new(
                   aggregate: account, id: "business",
                   state: { amount: { "cents" => 250 }, kind: { "label" => "business" },
                            denomination: { "code" => "USD" } }
                 ))

    edges = "#{edge_source(from: l1, to: l2)}\n#{edge_source_v3(from: l2, to: l3)}"
    check!(V3_SOURCE, translation_source: edges)

    db = PG.connect(dbname: LINEAGE_DB)
    layered = db.exec(
      "SELECT aggregate_id, operation, state FROM " \
      "#{PG::Connection.quote_ident("ledger_account_lineage_3_#{l3}")} ORDER BY aggregate_id"
    ).values

    definition = db.exec_params("SELECT definition FROM pg_matviews WHERE matviewname = $1",
                                ["ledger_account_lineage_3_#{l3}"])[0]["definition"]
    expect(definition).to include("ledger_account_lineage_2_#{l2}")

    lineage = Hecks::Adapters::PostgresEra::Lineage.new(db, "Ledger")
    chain = Hecks::Adapters::PostgresEra::LineageManager.edge_chain(
      load_registry(V3_SOURCE, translation_source: edges), load_registry(V3_SOURCE).bluebooks.values.first,
      lineage.eras[0..-2], l3
    )
    full = db.exec(
      "SELECT aggregate_id, operation, state FROM " \
      "(#{lineage.chain_sql(account, 3, chain)}) full_build ORDER BY aggregate_id"
    ).values
    db.close

    expect(layered).to eq(full)
    expect(layered).not_to be_empty
  end

  # The same equivalence for a rekey, which reaches layered_chain_sql's id_column case
  # (Translation::RuleCompiler.id_case) that a rename edge never does; without it a rekey could
  # preview one answer at audit time and mint another. Same one-mint, two-build shape.
  # rubocop:disable-next RSpec/ExampleLength
  it "produces the identical id under a REKEY too — the layered build's id_column CASE agrees with the full one" do
    write_v1_record
    l1 = label_of(V1_SOURCE)
    l2 = label_of(V2_SOURCE)
    l3 = label_of(V3_REKEYED_SOURCE)
    check!(V2_SOURCE, translation_source: edge_source(from: l1, to: l2))

    # more era-2 traffic; kind "personal" avoids colliding with "business" on the same new id
    # (a rekey collapses onto `kind.label`), which would trip the audit's count-preservation gate.
    registry = load_registry(V2_SOURCE)
    account = registry.bluebooks.values.first.aggregate("Account")
    adapter = Hecks::Adapters::PostgresEra.new(aggregate: account, settings: { database: LINEAGE_DB, domain: "Ledger" })
    adapter.save(Hecks::Runtime::Instance.new(
                   aggregate: account, id: "personal",
                   state: { amount: { "cents" => 250 }, kind: { "label" => "personal" },
                            denomination: { "code" => "USD" } }
                 ))

    rekey_edge = edge_source_v3_rekey(from: l2, to: l3)
    edges = "#{edge_source(from: l1, to: l2)}\n#{rekey_edge}"
    drifted = load_registry(V3_REKEYED_SOURCE, translation_source: edges)

    # a rekey's only verification is the audit's human-approved sample; the mint refuses without it
    expect do
      Hecks::Adapters::PostgresEra::LineageManager.check!(
        registry: drifted, bluebook: drifted.bluebooks.values.first,
        current_text: V3_REKEYED_SOURCE, settings: { database: owner_url }
      )
    end.to raise_error(Hecks::Runtime::WiringError, /this edge carries a compute or rekey rule/)

    db = PG.connect(dbname: LINEAGE_DB)
    ledger_lineage = Hecks::Adapters::PostgresEra::Lineage.new(db, "Ledger")
    ledger_lineage.record_approval!(
      from: l2, to: l3,
      edge_digest: Hecks::Translation::Audit.edge_digest(drifted.translations.find { |t| t.from == l2 && t.to == l3 })
    )
    db.close

    Hecks::Adapters::PostgresEra::LineageManager.check!(
      registry: drifted, bluebook: drifted.bluebooks.values.first,
      current_text: V3_REKEYED_SOURCE, settings: { database: owner_url }
    )

    db = PG.connect(dbname: LINEAGE_DB)
    layered = db.exec(
      "SELECT aggregate_id, operation, state FROM " \
      "#{PG::Connection.quote_ident("ledger_account_lineage_3_#{l3}")} ORDER BY aggregate_id"
    ).values

    definition = db.exec_params("SELECT definition FROM pg_matviews WHERE matviewname = $1",
                                ["ledger_account_lineage_3_#{l3}"])[0]["definition"]
    expect(definition).to include("ledger_account_lineage_2_#{l2}")

    # ...and it agrees with the from-scratch build, ids included
    lineage = Hecks::Adapters::PostgresEra::Lineage.new(db, "Ledger")
    chain = Hecks::Adapters::PostgresEra::LineageManager.edge_chain(
      load_registry(V3_REKEYED_SOURCE, translation_source: edges), load_registry(V3_REKEYED_SOURCE).bluebooks.values.first,
      lineage.eras[0..-2], l3
    )
    full = db.exec(
      "SELECT aggregate_id, operation, state FROM " \
      "(#{lineage.chain_sql(account, 3, chain)}) full_build ORDER BY aggregate_id"
    ).values
    db.close

    expect(layered).to eq(full)
    expect(layered).not_to be_empty
    expect(layered.map(&:first)).to include("ref-business")
  end

  it "the layered build still honours the cut — an era-2 checkout writing after era 3 was minted never reaches era 3's head" do
    write_v1_record
    l1 = label_of(V1_SOURCE)
    l2 = label_of(V2_SOURCE)
    l3 = label_of(V3_SOURCE)
    check!(V2_SOURCE, translation_source: edge_source(from: l1, to: l2))
    edges = "#{edge_source(from: l1, to: l2)}\n#{edge_source_v3(from: l2, to: l3)}"
    check!(V3_SOURCE, translation_source: edges)

    # An old era-2 checkout keeps writing after era 3 cut its watermark; if the cut were
    # re-derived at query time the write would leak upward through era 2's matview.
    stale = Hecks::Adapters::PostgresEra.new(
      aggregate: load_registry(V2_SOURCE).bluebooks.values.first.aggregate("Account"),
      settings:  { database: LINEAGE_DB, domain: "Ledger", era: 2 }
    )
    stale.save(Hecks::Runtime::Instance.new(
                 aggregate: load_registry(V2_SOURCE).bluebooks.values.first.aggregate("Account"),
                 id: "business", state: { amount: { "cents" => 999 }, kind: { "label" => "business" },
                                          denomination: { "code" => "ZZZ" } }
               ))

    db = PG.connect(dbname: LINEAGE_DB)
    # The refresh is the point: a materialized tail is frozen anyway, so the cut only proves
    # itself when the definition is re-evaluated (the header promises it holds on a full refresh).
    db.exec("REFRESH MATERIALIZED VIEW #{PG::Connection.quote_ident("ledger_account_lineage_3_#{l3}")}")
    head = db.exec("SELECT id, state FROM ledger_account_head ORDER BY id").values
    diverged = Hecks::Adapters::PostgresEra::Lineage.new(db, "Ledger").diverged_count(2)
    db.close

    expect(diverged).to eq(1)
    expect(head.map(&:last).join).not_to include("999")
    expect(head.map(&:last).join).not_to include("ZZZ")
  end

  it "journal rows accept no UPDATE or DELETE from PUBLIC — immutability by privilege" do
    check!(V1_SOURCE)
    db = PG.connect(dbname: LINEAGE_DB)
    # Ask Postgres directly: on a fresh database relacl stays NULL (the guarded REVOKE in
    # provisioning.rb never fires when public holds nothing), so asserting non-nil would be wrong.
    update_allowed = db.exec("SELECT has_table_privilege('public', 'hecks_journal_ledger', 'UPDATE')")[0]["has_table_privilege"]
    delete_allowed = db.exec("SELECT has_table_privilege('public', 'hecks_journal_ledger', 'DELETE')")[0]["has_table_privilege"]
    db.close
    expect(update_allowed).to eq("f")
    expect(delete_allowed).to eq("f")
  end

  it "holds the code path and the compiled matview to the same answer — the cross-execution equivalence gate" do
    write_v1_record
    from = label_of(V1_SOURCE)
    to = label_of(V2_SOURCE)
    registry = check!(V2_SOURCE, translation_source: edge_source(from: from, to: to))

    # the reference semantics: the port-level entry-JSON transform
    edge = registry.translations.first
    declared = edge.for_aggregate("Account")
    rules = Hecks::Ports::Persistence::Lineage.from_declared(declared, "Account")
    entry = Hecks::Ports::Persistence::Entry.new(
      operation: "save", id: "a1",
      state: { cost: { "cents" => 100, "currency" => "USD" }, kind: { "label" => "biz" }, legacy_note: { "text" => "keep?" } }
    )
    reference = JSON.parse(JSON.generate(rules.translate(entry).state))

    db = PG.connect(dbname: LINEAGE_DB)
    matview = db.exec("SELECT matviewname FROM pg_matviews")[0]["matviewname"]
    expect(matview).to eq("ledger_account_lineage_2_#{to}")
    compiled = JSON.parse(db.exec("SELECT state FROM #{matview} WHERE aggregate_id = 'a1'")[0]["state"])
    db.close

    expect(compiled).to eq(reference)
  end
end
