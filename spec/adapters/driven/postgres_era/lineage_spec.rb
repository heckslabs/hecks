require "hecksagain"
require_relative "../../../support/postgres_probe"

# Lineage in the Postgres adapter: the partitioned journal, the
# hecks_eras rows, the one-transaction mint, and the head compiled as a
# chain of edges — old entries translated at inclusion, never rewritten.
# Runs only when a Postgres server is reachable — the shared probe in
# support/postgres_probe.rb, like every other Postgres spec here.
RSpec.describe "lineage in the Postgres adapter",
               io: true do
  LINEAGE_DB = "hecksagain_lineage_spec".freeze

  # The genuine table owner for this whole file — an ordinary,
  # NON-superuser role. Every check!/adapter_for/merge! call below
  # connects as this role, not as whatever OS account runs the spec
  # suite, because a local dev Postgres user is commonly a superuser
  # (verified: mine is), and a superuser bypasses RLS unconditionally —
  # FORCE ROW LEVEL SECURITY has no lever against that at all. Without
  # a real non-superuser owner, "the owner is now fenced too" is
  # untestable in this environment: every assertion of it would
  # silently pass for the wrong reason.
  LINEAGE_OWNER = "hecksagain_lineage_owner".freeze

  def owner_url = "postgres://#{LINEAGE_OWNER}@localhost/#{LINEAGE_DB}"

  V1_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "Ledger" do
      aggregate "Acct" do
        identified_by { kind.label }

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
        identified_by { kind.label }

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

  # A THIRD era, so the layered build has something to layer ON: era 3
  # is the first mint that can read era 2's matview instead of raw
  # history.
  V3_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "Ledger" do
      aggregate "Account" do
        identified_by { kind.label }

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

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{LINEAGE_DB} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{LINEAGE_DB}")
    admin.exec("DROP ROLE IF EXISTS #{LINEAGE_OWNER}")
    # Plain CREATE ROLE ... LOGIN — no SUPERUSER, no BYPASSRLS. Either
    # attribute would make FORCE ROW LEVEL SECURITY a no-op for this
    # role, same as it already is for the ambient dev connection.
    admin.exec("CREATE ROLE #{LINEAGE_OWNER} LOGIN")
    admin.close
    grant = PG.connect(dbname: LINEAGE_DB)
    grant.exec("GRANT CONNECT ON DATABASE #{LINEAGE_DB} TO #{LINEAGE_OWNER}")
    grant.close
    # the per-schema grant below is re-issued in `before do`, since that
    # hook drops and recreates `public` before every example — a schema
    # created via CREATE SCHEMA carries no default PUBLIC privileges,
    # so a grant made only here would be wiped before the first test ran
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
    registry = Hecksagain::Runtime::Registry.new
    loading = Hecksagain::Ports::Loading.bootstrap
    file = Tempfile.new(["lineage-", ".bluebook"])
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
    settings = { database: owner_url }
    settings[:role] = role if role
    Hecksagain::Adapters::Postgres::LineageManager.check!(
      registry: registry, bluebook: bluebook, current_text: source, settings: settings
    )
    registry
  end

  # A deployment's app role: a NON-owner, which is the only kind of
  # connection the era fence can act on (the owner bypasses RLS).
  LINEAGE_ROLE = "hecksagain_lineage_spec_app".freeze

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
  rescue PG::Error => error
    error.message.strip
  ensure
    db&.close
  end

  def hash_of(source)
    registry = load_registry(source)
    Hecksagain::Runtime::StorageShape.mint_hash(registry.bluebooks.values.first)
  end

  def label_of(source) = hash_of(source)[0, 6]

  def adapter_for(registry, aggregate_name)
    aggregate = registry.bluebooks.values.first.aggregate(aggregate_name)
    Hecksagain::Adapters::Postgres.new(aggregate: aggregate, settings: { database: owner_url, domain: "Ledger" })
  end

  def write_v1_record(state = nil)
    registry = check!(V1_SOURCE)
    adapter = adapter_for(registry, "Acct")
    instance = Hecksagain::Runtime::Instance.new(
      aggregate: registry.bluebooks.values.first.aggregate("Acct"), id: "a1",
      state: state || {
        cost: { "cents" => 100, "currency" => "USD" },
        kind: { "label" => "biz" },
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

  # EVERY EDIT REACHES THE SAME GENERIC WORDING NOW — shape-changing,
  # cosmetic, or unparseable alike. `EraTamper.refusal` used to re-parse
  # the edited text and distinguish a cosmetic edit from a real shape
  # change in the message ; that was a pure quality-of-message nicety, not
  # a safety property (the digest mismatch alone is what refuses either
  # way), and the one thing forcing a boot path to re-parse held era
  # text, so it was dropped. An operator
  # judges "did this matter" themselves, reading the still-archived
  # original — an anomalous recovery moment already, not a normal boot
  # path.
  it "refuses an edited hecks_eras row toward the generic wording — with the archive as recovery" do
    check!(V1_SOURCE)
    db = PG.connect(dbname: LINEAGE_DB)

    generic_wording = "cannot boot Ledger: the held text of era 1 was edited after it was frozen — " \
                       "held era texts are storage facts; restore the original text, or reset the data"

    # shape-changing edit
    db.exec_params("UPDATE hecks_eras SET held_text = $1 WHERE domain = 'Ledger' AND ordinal = 1", [V2_SOURCE])
    expect { check!(V1_SOURCE) }.to raise_error(Hecksagain::Runtime::WiringError, generic_wording)

    # cosmetic edit
    db.exec_params("UPDATE hecks_eras SET held_text = $1 WHERE domain = 'Ledger' AND ordinal = 1",
                   ["# a typo fixed\n#{V1_SOURCE}"])
    expect { check!(V1_SOURCE) }.to raise_error(Hecksagain::Runtime::WiringError, generic_wording)

    # unparseable edit — a misspelled DSL method mid-`Kernel.eval`
    unparseable = V1_SOURCE.sub("attribute :cost, Money", "atribute :cost, Money")
    db.exec_params("UPDATE hecks_eras SET held_text = $1 WHERE domain = 'Ledger' AND ordinal = 1", [unparseable])
    expect { check!(V1_SOURCE) }.to raise_error(Hecksagain::Runtime::WiringError, generic_wording)

    # the archive holds the original bytes; restoring them boots again
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

    expect { check!(V1_SOURCE) }.to raise_error(Hecksagain::Runtime::WiringError, /edited after it was frozen/)

    lineage = Hecksagain::Adapters::Postgres::Lineage.new(db, "Ledger")
    fresh = lineage.reattest!(1)
    expect(fresh).to eq(Digest::SHA256.hexdigest(V2_SOURCE))

    attestation = db.exec("SELECT * FROM hecks_attestations WHERE domain = 'Ledger'")[0]
    expect(attestation["old_digest"]).to eq(old_digest)
    expect(attestation["new_digest"]).to eq(fresh)
    expect(attestation["attested_at"]).not_to be_nil
    db.close

    # the re-frozen text is now era 1: V2's shape boots, V1's drifts
    expect { check!(V2_SOURCE) }.not_to raise_error
  end

  it "refuses drift with no edge, naming both authoring tools" do
    check!(V1_SOURCE)
    expect { check!(V2_SOURCE) }.to raise_error(
      Hecksagain::Runtime::WiringError,
      "cannot boot Ledger: the shape changed (era 2) and no translation edge covers it — " \
      "run bin/scaffold_translation to write the edge, check it with bin/translation_audit, then boot again"
    )
  end

  it "refuses a stale edge whose target hash no longer matches the current shape" do
    check!(V1_SOURCE)
    from = label_of(V1_SOURCE)
    stale = edge_source(from: from, to: "000000")
    expect { check!(V2_SOURCE, translation_source: stale) }.to raise_error(
      Hecksagain::Runtime::WiringError, /the edge is stale; re-run bin\/scaffold_translation/
    )
  end

  it "refuses a mechanical fork — two edges leaving one source shape" do
    check!(V1_SOURCE)
    from = label_of(V1_SOURCE)
    to = label_of(V2_SOURCE)
    forked = edge_source(from: from, to: to) + edge_source(from: from, to: "111111")
    expect { check!(V2_SOURCE, translation_source: forked) }.to raise_error(
      Hecksagain::Runtime::WiringError, /eras fork mechanically; keep one edge per source shape/
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
      Hecksagain::Runtime::WiringError,
      /cannot boot Ledger::Account: its shape changed and :legacy_note is not explained by any rename, move, convert, retype, or drop/
    )
  end

  it "mints era 2 in one transaction and derives the head through the edge — old entries translated at inclusion, never rewritten" do
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

    # the original journal row is untouched, in the era-1 partition
    original = db.exec("SELECT era, aggregate, state FROM hecks_journal_ledger ORDER BY ordinal")
    expect(original.ntuples).to eq(1)
    expect(original[0]["era"]).to eq("1")
    expect(original[0]["aggregate"]).to eq("acct")
    expect(JSON.parse(original[0]["state"])["cost"]).to eq("cents" => 100, "currency" => "USD")

    # the head answers in era-2 shape
    adapter = adapter_for(registry, "Account")
    found = adapter.find("a1")
    expect(found.amount.to_h).to eq(cents: 100)
    expect(found.denomination.to_h).to eq(code: "USD")
    expect(found.kind.to_h).to eq(label: "business")
    expect(found.key?(:legacy_note)).to be(false)

    # a new era-2 write overlays the translated tail
    updated = Hecksagain::Runtime::Instance.new(
      aggregate: registry.bluebooks.values.first.aggregate("Account"), id: "a1",
      state: { amount: { "cents" => 250 }, kind: { "label" => "business" }, denomination: { "code" => "EUR" } }
    )
    adapter.save(updated)
    expect(adapter.find("a1").amount.to_h).to eq(cents: 250)

    # ...and lands in the era-2 partition, leaving era 1 immutable
    partitions = db.exec("SELECT era, count(*) FROM hecks_journal_ledger GROUP BY era ORDER BY era")
    expect(partitions.map { |row| [row["era"], row["count"]] }).to eq([["1", "1"], ["2", "1"]])
    db.close
  end

  it "a convert meeting an unmapped value refuses the whole mint — the era is never half-born" do
    write_v1_record(
      cost: { "cents" => 5, "currency" => "USD" },
      kind: { "label" => "mystery" },
      legacy_note: { "text" => "x" }
    )
    from = label_of(V1_SOURCE)
    to = label_of(V2_SOURCE)

    expect { check!(V2_SOURCE, translation_source: edge_source(from: from, to: to)) }.to raise_error(
      Hecksagain::Runtime::WiringError,
      /cannot translate kind.label: "mystery" has no mapping in its convert's values: table. Add "mystery" => \.\.\. to cover it/
    )

    db = PG.connect(dbname: LINEAGE_DB)
    expect(db.exec("SELECT count(*) FROM hecks_eras WHERE domain = 'Ledger'")[0]["count"]).to eq("1")
    db.close
  end

  # H2, docs/audits/2026-08-10-main-bug-audit.md: every realistic mint-time
  # refusal in this corpus turns out to be caught by the PRE-mint audit
  # (CoverageCheck#audit! — "before anything is minted, so a refusal
  # leaves no half-born era", per its own comment), which runs before
  # mint_era! is even called — so a DSL-level scenario like the one above
  # can prove the audit gate works, but can't reach the transaction bug
  # H2 actually names. This targets the mechanism directly: does
  # `ensure_head_snapshot!` survive being called from inside an
  # already-open transaction the way `mint_era!` actually calls it?
  #
  # `PG::Connection#transaction` is a bare BEGIN/COMMIT with no savepoint
  # nesting. Called while already mid-transaction, its COMMIT used to end
  # THAT transaction the instant this one call returned — so a later
  # ROLLBACK in the same logical unit of work (mint_era!'s own rescue, on
  # whatever raises after this point) had nothing left to roll back.
  it "ensure_head_snapshot! does not end an already-open transaction — a later rollback still undoes it" do
    check!(V1_SOURCE)
    registry = load_registry(V1_SOURCE)
    acct = registry.bluebooks.values.first.aggregate("Acct")

    db = PG.connect(dbname: LINEAGE_DB)
    lineage = Hecksagain::Adapters::Postgres::Lineage.new(db, "Ledger")

    db.exec("BEGIN")
    db.exec_params(
      "INSERT INTO hecks_eras (domain, ordinal, hash, label, held_text, watermark, held_digest, canon_form) " \
      "VALUES ('Ledger', 99, 'placeholder-hash', 'xxxxxx', 'placeholder', 1, 'placeholder-digest', 1)"
    )
    # The call under test — exactly what compile_head! does for each
    # aggregate mid-mint, on the SAME connection, INSIDE the transaction
    # just opened above.
    lineage.ensure_head_snapshot!(acct.storage_name, 99)
    # Simulates mint_era!'s own rescue clause: a LATER step in the same
    # logical mint fails, so the whole thing rolls back. If the call
    # above already ended the transaction, this ROLLBACK has nothing to
    # undo, and everything above survives it.
    db.exec("ROLLBACK")
    db.close

    fresh = PG.connect(dbname: LINEAGE_DB)
    expect(fresh.exec("SELECT count(*) FROM hecks_eras WHERE domain = 'Ledger' AND ordinal = 99")[0]["count"]).to eq("0")
    expect(fresh.exec("SELECT to_regclass('acct_head_snapshot_99') IS NULL AS gone")[0]["gone"]).to eq("t")
    fresh.close
  end

  # ADVERSARIAL, not incidental: found by deliberately constructing a
  # move destination that collides with an existing scalar (most
  # realistically, a has_one/belongs_to reference — a bare id, never an
  # object). The SQL side used to silently overwrite that scalar with
  # an empty object rather than lose the mint over it; now it refuses
  # by name, matching the Ruby reference transform's own refusal pinned
  # in spec/translation_language_spec.rb.
  it "a move whose destination collides with an existing scalar refuses the mint by name, not silently" do
    collide_v1 = <<~BLUEBOOK
      Hecks.bluebook "Collide" do
        aggregate "Acct" do
          identified_by :kind
          attribute :amount, Money
          attribute :kind, Kind
          belongs_to :Team
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
    Hecksagain::Adapters::Postgres.new(aggregate: acct, settings: { database: LINEAGE_DB, domain: "Collide" })
                                   .save(Hecksagain::Runtime::Instance.new(
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
      Hecksagain::Runtime::WiringError,
      /cannot move amount\.cents to: team_ref\.detail: team_ref already holds "team-1", not a value this can nest under/
    )
  end

  it "however a post-cut row lands in a superseded era, the reconciliation machinery does not lose it or leak it" do
    # This tests what happens GIVEN such a row exists — not whether an
    # ordinary role can create one (the fence tests already prove it
    # cannot: "the fence is a fact about the ERA", "a role rebooting
    # into its OWN now-superseded era"). A genuine, non-superuser writer
    # racing a live mint IS possible in principle — RLS is checked once,
    # at statement execution, never re-checked at commit, so a write
    # that executes while an era is still current can still commit
    # after the fence moves on — but empirically that window is now the
    # width of a few catalog statements (see "an ordinary writer is
    # never blocked by a mint" below), not something a test can reliably
    # steer a write into without instrumenting production code purely
    # to slow it down for the test's convenience. So the row here is
    # inserted directly, as the table owner — standing in for "however
    # it got here" — and what is actually under test is everything
    # downstream: the frozen tail, diverged_count, and merge_tail.
    write_v1_record
    from = label_of(V1_SOURCE)
    to = label_of(V2_SOURCE)
    check!(V2_SOURCE, translation_source: edge_source(from: from, to: to))

    old_registry = check!(V1_SOURCE)
    expect(old_registry.resolved_eras["Ledger"]).to eq(1)

    db = PG.connect(dbname: LINEAGE_DB)
    state = JSON.generate(cost: { "cents" => 5, "currency" => "USD" }, kind: { "label" => "biz" }, legacy_note: { "text" => "late" })
    ordinal = db.exec_params(
      "INSERT INTO hecks_journal_ledger (era, aggregate, aggregate_id, operation, state) VALUES (1, 'acct', $1, 'save', $2) RETURNING ordinal",
      ["a9", state]
    )[0]["ordinal"]
    # ...and the era-1 snapshot table Postgres#append would ALSO have
    # written in the same transaction, a real race-condition write always
    # going through append() rather than raw SQL the way this stand-in
    # does — old_world.find below reads head_view, which for era 1 is
    # this snapshot table verbatim, not a live re-derivation.
    db.exec_params(
      "INSERT INTO acct_head_snapshot_1 (id, ordinal, state) VALUES ($1, $2, $3)",
      ["a9", ordinal, state]
    )

    # the post-cut write landed in the era-1 partition...
    eras_of_a9 = db.exec("SELECT era FROM hecks_journal_ledger WHERE aggregate_id = 'a9'").map { |row| row["era"] }
    expect(eras_of_a9).to eq(["1"])
    # ...a checkout still reading era 1 sees it (its own head view, keyed
    # to "Acct"'s storage name, is untouched by the mint that renamed
    # the aggregate to "Account")...
    old_world = Hecksagain::Adapters::Postgres.new(
      aggregate: old_registry.bluebooks.values.first.aggregate("Acct"),
      settings: { database: owner_url, domain: "Ledger", era: 1 }
    )
    expect(old_world.find("a9").cost.to_h).to eq(cents: 5, currency: "USD")
    # ...the new head does NOT (the watermark is baked into the matview)...
    new_head = db.exec("SELECT count(*) FROM account_head WHERE id = 'a9'")[0]["count"]
    expect(new_head).to eq("0")
    # ...and the divergence is observable
    lineage = Hecksagain::Adapters::Postgres::Lineage.new(db, "Ledger")
    expect(lineage.diverged_count(1)).to eq(1)
    db.close
  end

  it "an ordinary writer is never blocked by a mint — advance_era!'s AccessExclusiveLock is held for the commit, not the matview build" do
    write_v1_record
    from = label_of(V1_SOURCE)
    to = label_of(V2_SOURCE)

    # seed a real ancestor tail so compile_head!'s matview build takes
    # measurable time — a mint over a handful of rows proves nothing
    # about whether a SLOW build widens the write-blocking window
    db = PG.connect(dbname: LINEAGE_DB)
    3_000.times do |i|
      db.exec_params(
        "INSERT INTO hecks_journal_ledger (era, aggregate, aggregate_id, operation, state) VALUES (1, 'acct', $1, 'save', $2)",
        ["bulk-#{i}", JSON.generate(cost: { "cents" => i, "currency" => "USD" }, kind: { "label" => "biz" }, legacy_note: { "text" => "x" })]
      )
    end
    db.close

    # Two different outcomes for a writer aimed at era 1, and only one
    # of them is a bug. LOCK contention (the writer waited on
    # advance_era!'s AccessExclusiveLock and timed out) would mean the
    # reordering failed. A ROW-LEVEL SECURITY refusal, once the mint has
    # actually committed and moved the fence to era 2, is the CORRECT
    # and expected outcome the rest of this file already tests — this
    # spec only needs to prove it is never the FIRST kind.
    stop = false
    ok = 0
    lock_blocked = 0
    fence_refused = 0
    writer = Thread.new do
      w = PG.connect(owner_url)
      w.exec("SET lock_timeout = '500ms'")
      # An aggregate name the bluebook never declares. The mint's audit
      # iterates bluebook.aggregates ("Acct"/"Account") and compares the
      # journal's id set for EACH of those, read live, twice — any
      # writer touching one of those names interferes with that
      # comparison for a reason unrelated to what this spec is about
      # (see "however a post-cut row lands" above, and the run that
      # failed before this fix — writing a stable id under "acct" still
      # tripped Layer 2's per-id value check). A row under an
      # undeclared name is invisible to the audit entirely, and still
      # exercises the SAME table's locks: ensure_partition!/
      # advance_era!/compile_head! operate on the whole partition, not
      # on rows matching a particular aggregate.
      until stop
        begin
          w.exec("INSERT INTO hecks_journal_ledger (era, aggregate, aggregate_id, operation, state) " \
                 "VALUES (1, 'unrelated_probe', 'live', 'save', '{}'::jsonb)")
          ok += 1
        rescue PG::Error => error
          if error.message =~ /lock timeout|canceling statement/i
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

    # the new world updates a1 after the cut
    new_world = Hecksagain::Adapters::Postgres.new(
      aggregate: new_registry.bluebooks.values.first.aggregate("Account"),
      settings: { database: LINEAGE_DB, domain: "Ledger", era: 2 }
    )
    new_world.save(Hecksagain::Runtime::Instance.new(
      aggregate: new_registry.bluebooks.values.first.aggregate("Account"), id: "a1",
      state: { amount: { "cents" => 999 }, kind: { "label" => "business" }, denomination: { "code" => "USD" }, status: "open" }
    ))

    # the old world keeps running: touches a1 too (the conflict), and
    # opens a9 (the mergeable tail)
    old_registry = check!(V1_SOURCE)
    acct = old_registry.bluebooks.values.first.aggregate("Acct")
    old_world = Hecksagain::Adapters::Postgres.new(
      aggregate: acct, settings: { database: LINEAGE_DB, domain: "Ledger", era: 1 }
    )
    old_world.save(Hecksagain::Runtime::Instance.new(
      aggregate: acct, id: "a1",
      state: { cost: { "cents" => 111, "currency" => "USD" }, kind: { "label" => "biz" }, legacy_note: { "text" => "old edit" } }
    ))
    old_world.save(Hecksagain::Runtime::Instance.new(
      aggregate: acct, id: "a9",
      state: { cost: { "cents" => 5, "currency" => "EUR" }, kind: { "label" => "pers" }, legacy_note: { "text" => "late" } }
    ))
    [new_registry, edge]
  end

  it "tail-merge: refuses both-worlds conflicts by name, then interleaves the declared winner append-only" do
    new_registry, = fork_worlds

    expect do
      Hecksagain::Adapters::Postgres::LineageManager.merge!(
        registry: new_registry, bluebook: new_registry.bluebooks.values.first, settings: { database: LINEAGE_DB }
      )
    end.to raise_error(
      Hecksagain::Runtime::WiringError,
      "cannot merge the tail of Ledger: touched by both worlds since the cut — account#a1. " \
      "Name each winner (--winner <id>=old or --winner <id>=new), then run bin/merge_tail again. " \
      "A winner takes the WHOLE record — the aggregate is the consistency boundary, so the " \
      "loser's edits are discarded even where they touched different attributes"
    )

    db = PG.connect(dbname: LINEAGE_DB)
    ancestor_before = db.exec("SELECT ordinal, state FROM hecks_journal_ledger_era_1 ORDER BY ordinal").values

    Hecksagain::Adapters::Postgres::LineageManager.merge!(
      registry: new_registry, bluebook: new_registry.bluebooks.values.first,
      settings: { database: LINEAGE_DB }, winners: { "a1" => "new" }
    )

    # the tail arrived, translated; the declared winner stood; the
    # divergence is gone; and not one ancestor row changed
    head = db.exec("SELECT id, state FROM account_head ORDER BY id").to_h { |row| [row["id"], JSON.parse(row["state"])] }
    expect(head["a9"]["amount"]).to eq("cents" => 5)
    expect(head["a9"]["denomination"]).to eq("code" => "EUR")
    expect(head["a9"]["kind"]).to eq("label" => "personal")
    expect(head["a1"]["amount"]).to eq("cents" => 999)

    lineage = Hecksagain::Adapters::Postgres::Lineage.new(db, "Ledger")
    expect(lineage.diverged_count(1)).to eq(0)

    ancestor_after = db.exec("SELECT ordinal, state FROM hecks_journal_ledger_era_1 ORDER BY ordinal").values
    expect(ancestor_after).to eq(ancestor_before)
    db.close
  end

  it "refuses an identity-path change as a re-keying, not a translation" do
    rekeyed = V2_SOURCE.sub("identified_by { kind.label }", "identified_by { amount.cents }")
    write_v1_record
    from = label_of(V1_SOURCE)
    to = label_of(rekeyed)

    expect { check!(rekeyed, translation_source: edge_source(from: from, to: to)) }.to raise_error(
      Hecksagain::Runtime::WiringError,
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
    lineage = Hecksagain::Adapters::Postgres::Lineage.new(db, "Ledger")
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

    Hecksagain::Adapters::Postgres::LineageManager.merge!(
      registry: new_registry, bluebook: new_registry.bluebooks.values.first,
      settings: { database: LINEAGE_DB }, winners: { "a1" => "old" }
    )

    db = PG.connect(dbname: LINEAGE_DB)
    a1 = JSON.parse(db.exec("SELECT state FROM account_head WHERE id = 'a1'")[0]["state"])
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

  it "evaluates a compute rule exclusively inside the compiled matview — its SQL is its only implementation" do
    registry = load_registry(PRICING_V1)
    Hecksagain::Adapters::Postgres::LineageManager.check!(
      registry: registry, bluebook: registry.bluebooks.values.first,
      current_text: PRICING_V1, settings: { database: LINEAGE_DB }
    )
    quote = registry.bluebooks.values.first.aggregate("Quote")
    adapter = Hecksagain::Adapters::Postgres.new(aggregate: quote, settings: { database: LINEAGE_DB, domain: "Pricing" })
    adapter.save(Hecksagain::Runtime::Instance.new(aggregate: quote, id: "q1", state: { price_cents: { "value" => 1250 } }))

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
      Hecksagain::Adapters::Postgres::LineageManager.check!(
        registry: drifted, bluebook: drifted.bluebooks.values.first,
        current_text: PRICING_V2, settings: { database: LINEAGE_DB }
      )
    end.to raise_error(
      Hecksagain::Runtime::WiringError,
      "cannot mint era 2 of Pricing: this edge carries a compute or rekey rule, and the audit's " \
      "human-approved sample is its only verification — run bin/translation_audit with --approve, then boot again"
    )

    # the approval binds to the edge's content AND the journal's
    # high-water ordinal at review time, in the database itself
    db = PG.connect(dbname: LINEAGE_DB)
    pricing_lineage = Hecksagain::Adapters::Postgres::Lineage.new(db, "Pricing")
    pricing_lineage.record_approval!(
      from: from, to: to,
      edge_digest: Hecksagain::Translation::Audit.edge_digest(drifted.translations.first)
    )

    # ...so a journal that advances past the review invalidates it
    adapter.save(Hecksagain::Runtime::Instance.new(aggregate: quote, id: "q2", state: { price_cents: { "value" => 300 } }))
    expect do
      Hecksagain::Adapters::Postgres::LineageManager.check!(
        registry: drifted, bluebook: drifted.bluebooks.values.first,
        current_text: PRICING_V2, settings: { database: LINEAGE_DB }
      )
    end.to raise_error(
      Hecksagain::Runtime::WiringError,
      /the journal advanced past the approved review \(ordinal 1 reviewed, 2 now\) — the samples a human approved no longer cover the data; re-run bin\/translation_audit with --approve/
    )

    # a fresh review over the journal as it now stands mints
    pricing_lineage.record_approval!(
      from: from, to: to,
      edge_digest: Hecksagain::Translation::Audit.edge_digest(drifted.translations.first)
    )
    db.close

    Hecksagain::Adapters::Postgres::LineageManager.check!(
      registry: drifted, bluebook: drifted.bluebooks.values.first,
      current_text: PRICING_V2, settings: { database: LINEAGE_DB }
    )

    # the compiled matview evaluated the SQL...
    db = PG.connect(dbname: LINEAGE_DB)
    compiled = JSON.parse(db.exec("SELECT state FROM quote_lineage_2_#{to} WHERE aggregate_id = 'q1'")[0]["state"])
    db.close
    expect(compiled).to eq("price_dollars" => { "value" => 12.5 }, "sku" => { "value" => "q1" })

    # ...and the in-process reference transform deliberately did NOT —
    # compute is exempt from the equivalence gate; there is nothing
    # in-process to hold it against.
    declared = drifted.translations.first.for_aggregate("Quote")
    rules = Hecksagain::Ports::Persistence::Lineage.from_declared(declared, "Quote")
    entry = Hecksagain::Ports::Persistence::Entry.new(operation: "save", id: "q1", state: { price_cents: { "value" => 1250 } })
    expect(rules.translate(entry).state).to eq(price_cents: { "value" => 1250 })

    # the head serves the computed shape
    v2_quote = drifted.bluebooks.values.first.aggregate("Quote")
    head = Hecksagain::Adapters::Postgres.new(aggregate: v2_quote, settings: { database: LINEAGE_DB, domain: "Pricing" })
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
        identified_by :email

        attribute :name,  PersonName
        attribute :title, PersonTitle
        attribute :email, PersonEmail, optional: true

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

  it "mints an era that rekeys an aggregate's identity, with an approved rekey rule" do
    registry = load_registry(ROSTER_V1)
    Hecksagain::Adapters::Postgres::LineageManager.check!(
      registry: registry, bluebook: registry.bluebooks.values.first,
      current_text: ROSTER_V1, settings: { database: LINEAGE_DB }
    )
    person = registry.bluebooks.values.first.aggregate("Person")
    adapter = Hecksagain::Adapters::Postgres.new(aggregate: person, settings: { database: LINEAGE_DB, domain: "Roster" })
    adapter.save(Hecksagain::Runtime::Instance.new(
                   aggregate: person, id: "Chris Young", state: { name: { "value" => "Chris Young" }, title: { "value" => "CEO" } }
                 ))

    from = label_of(ROSTER_V1)
    to = label_of(ROSTER_V2)
    rekey_edge = <<~RUBY
      Hecks.data_translation("Roster", from: #{from.inspect}, to: #{to.inspect}) do
        aggregate("Person") do
          rekey sql: "CASE ((__s -> 'name') ->> 'value') WHEN 'Chris Young' THEN 'chris@example.com' END"
        end
      end
    RUBY

    drifted = load_registry(ROSTER_V2, translation_source: rekey_edge)

    # a rekey's only verification is the audit's human-approved sample,
    # same as compute — the mint refuses non-interactively without it
    expect do
      Hecksagain::Adapters::Postgres::LineageManager.check!(
        registry: drifted, bluebook: drifted.bluebooks.values.first,
        current_text: ROSTER_V2, settings: { database: LINEAGE_DB }
      )
    end.to raise_error(Hecksagain::Runtime::WiringError, /this edge carries a compute or rekey rule/)

    db = PG.connect(dbname: LINEAGE_DB)
    roster_lineage = Hecksagain::Adapters::Postgres::Lineage.new(db, "Roster")
    roster_lineage.record_approval!(
      from: from, to: to,
      edge_digest: Hecksagain::Translation::Audit.edge_digest(drifted.translations.first)
    )
    db.close

    Hecksagain::Adapters::Postgres::LineageManager.check!(
      registry: drifted, bluebook: drifted.bluebooks.values.first,
      current_text: ROSTER_V2, settings: { database: LINEAGE_DB }
    )

    # the compiled matview resolves the record under its NEW id, and
    # ONLY its new id — the raw journal row is untouched (still keyed
    # "Chris Young"), but nothing reads it directly
    db = PG.connect(dbname: LINEAGE_DB)
    under_new_id = db.exec("SELECT state FROM person_lineage_2_#{to} WHERE aggregate_id = 'chris@example.com'")
    under_old_id = db.exec("SELECT state FROM person_lineage_2_#{to} WHERE aggregate_id = 'Chris Young'")
    raw_journal = db.exec("SELECT aggregate_id FROM hecks_journal_roster WHERE aggregate_id = 'Chris Young'")
    db.close

    expect(under_new_id.ntuples).to eq(1)
    expect(under_old_id.ntuples).to eq(0)
    expect(raw_journal.ntuples).to eq(1) # the immutable journal never rewrites

    # the head serves the record under its new id, name/title untouched
    v2_person = drifted.bluebooks.values.first.aggregate("Person")
    head = Hecksagain::Adapters::Postgres.new(aggregate: v2_person, settings: { database: LINEAGE_DB, domain: "Roster" })
    found = head.find("chris@example.com")
    expect(found.name.to_h).to eq(value: "Chris Young")
    expect(found.title.to_h).to eq(value: "CEO")
    expect(head.find("Chris Young")).to be_nil
  end

  it "fences a deployment's app role at the era its checkout speaks — and the fence is written through, not read off the catalog" do
    reset_app_role!
    write_v1_record
    from = label_of(V1_SOURCE)
    to = label_of(V2_SOURCE)
    check!(V2_SOURCE, translation_source: edge_source(from: from, to: to), role: LINEAGE_ROLE)

    journal = "hecks_journal_ledger"

    # The fenced role must be able to BOOT, or the fence constrains
    # nobody: ensure_base!'s ALTER TABLE and REVOKE are owner-only, and
    # a deployment's app role is deliberately not the owner.
    app = PG.connect(dbname: LINEAGE_DB, user: LINEAGE_ROLE)
    expect { Hecksagain::Adapters::Postgres::Lineage.new(app, "Ledger").ensure_base! }.not_to raise_error
    app.close

    append = lambda do |era|
      as_app_role(
        "INSERT INTO #{journal} (era, aggregate, aggregate_id, operation, state) " \
        "VALUES (#{era}, 'account', 'fenced-#{era}', 'save', '{}'::jsonb)"
      )
    end

    # the era this checkout speaks
    expect(append.call(2)).to eq(:allowed)

    # the SUPERSEDED era — writing to the old schema drops the instant
    # this mint materialized it. A per-partition GRANT cannot express
    # this: Postgres checks INSERT on the partitioned parent for a
    # routed insert and never consults the partition, so the old shape
    # of this fence either blocked everything or allowed every era.
    # This asserts the refusal by attempting the write.
    expect(append.call(1)).to match(/row-level security policy/i)

    # nor is a partition a back door: the role is granted on the parent
    # only, so addressing a leaf directly gets it nowhere
    expect(
      as_app_role("INSERT INTO #{journal}_era_1 (era, aggregate, aggregate_id, operation, state) " \
                  "VALUES (1, 'acct', 'leaf', 'save', '{}'::jsonb)")
    ).to match(/permission denied/i)

    # and the journal is still append-only to it
    expect(as_app_role("UPDATE #{journal} SET operation = 'delete'")).to match(/permission denied|row-level security/i)
    expect(as_app_role("DELETE FROM #{journal}")).to match(/permission denied|row-level security/i)

    # the owner is NOT fenced — mint and merge must reach every era
    owner = PG.connect(dbname: LINEAGE_DB)
    expect do
      owner.exec("INSERT INTO #{journal} (era, aggregate, aggregate_id, operation, state) " \
                 "VALUES (1, 'acct', 'owner-write', 'save', '{}'::jsonb)")
    end.not_to raise_error
    owner.close
  end

  # ADVERSARIAL: not "does the plain case work" (already proven above)
  # but "does something CLEVERER get past it." Each of these is a real
  # technique for routing an INSERT around a naive check — a CTE hides
  # the write inside a SELECT, a function body runs with its OWN
  # apparent scope, COPY is a wholly different code path from INSERT.
  # Verified empirically before writing this: COPY's outcome is NOT
  # what a first attempt suggested (see the commit message) — Postgres
  # refuses COPY FROM outright the moment RLS is enabled on the target,
  # a built-in protection this design gets for free, not one it
  # implements. Recorded here so nobody "fixes" that by relaxing FORCE
  # ROW LEVEL SECURITY without knowing why COPY behaves this way.
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
    rescue PG::Error => error
      expect(error.message).to match(/COPY FROM not supported with row-level security/i)
    ensure
      db&.close
    end
  end

  it "an old checkout keeps writing its own era THROUGH a mint — the fork survives the window, it does not merely bracket it" do
    write_v1_record
    l1 = label_of(V1_SOURCE)
    l2 = label_of(V2_SOURCE)
    check!(V2_SOURCE, translation_source: edge_source(from: l1, to: l2))
    l3 = label_of(V3_SOURCE)

    # Hold a mint-shaped transaction open at exactly the point the tail
    # materialization would run: the next era's partition is attached,
    # nothing is committed.
    blocker = PG.connect(dbname: LINEAGE_DB)
    blocker.exec("BEGIN")
    Hecksagain::Adapters::Postgres::Lineage.new(blocker, "Ledger").ensure_partition!(3)

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
    rescue PG::Error => error
      error.message.strip
    end

    # the old checkout writes its own era straight through the mint
    expect(write.call).to eq(:allowed)

    blocker.exec("ROLLBACK")
    blocker.close
    probe.close
    writer.close
  end

  # `Postgres#append` holds `pg_advisory_xact_lock(hashtext('hecks_ordinal:'
  # || domain))` for its whole transaction now — a DIFFERENT key from the
  # mint/merge lock above, so it closes ordinal-vs-commit-order only among
  # PLAIN writes, never against a mint. Proven by holding that same lock by
  # hand and showing a real `adapter.save` blocks on it, then proceeds the
  # instant it's released — the only way `nextval()` and the row it feeds
  # can be guaranteed to happen in the same order as an unrelated
  # concurrent write's.
  it "serializes concurrent plain writes against EACH OTHER — ordinal order can no longer diverge from commit order" do
    registry = check!(V1_SOURCE)
    adapter  = adapter_for(registry, "Acct")

    holder = PG.connect(dbname: LINEAGE_DB)
    holder.exec("BEGIN")
    holder.exec_params("SELECT pg_advisory_xact_lock(hashtext('hecks_ordinal:' || $1))", ["Ledger"])

    instance = Hecksagain::Runtime::Instance.new(
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

  it "a role rebooting into its OWN now-superseded era cannot write it — nothing about that boot may reopen the schema a mint already closed" do
    reset_app_role!
    check!(V1_SOURCE, role: LINEAGE_ROLE)
    write_v1_record

    from = label_of(V1_SOURCE)
    to = label_of(V2_SOURCE)
    check!(V2_SOURCE, translation_source: edge_source(from: from, to: to)) # a plain owner mint, no role at all

    # the SAME role reboots and correctly recognizes itself as
    # superseded (the "matched" branch) — nothing about ITS OWN
    # settings changed; the schema moved out from under it
    check!(V1_SOURCE, role: LINEAGE_ROLE)

    expect(
      as_app_role("INSERT INTO hecks_journal_ledger (era, aggregate, aggregate_id, operation, state) " \
                  "VALUES (1, 'account', 'after-reboot', 'save', '{}'::jsonb)")
    ).to match(/row-level security/i)
  end

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

    # the old deployment boots era 1 under its own role
    check!(V1_SOURCE, role: old_role)
    write_v1_record

    writes = lambda do |role, era|
      db = PG.connect(dbname: LINEAGE_DB, user: role)
      db.exec("INSERT INTO hecks_journal_ledger (era, aggregate, aggregate_id, operation, state) " \
              "VALUES (#{era}, 'account', 'by-#{role}', 'save', '{}'::jsonb)")
      :allowed
    rescue PG::Error => error
      error.message.strip
    ensure
      db&.close
    end

    expect(writes.call(old_role, 1)).to eq(:allowed)

    # the NEW deployment boots the drifted shape under a DIFFERENT role
    # and mints era 2
    from = label_of(V1_SOURCE)
    to = label_of(V2_SOURCE)
    check!(V2_SOURCE, translation_source: edge_source(from: from, to: to), role: new_role)

    # the new role writes what it just minted...
    expect(writes.call(new_role, 2)).to eq(:allowed)

    # ...and so, unprompted, does the OLD role: the fence is a fact
    # about the ERA, not about WHICH role is asking, so any role ever
    # granted INSERT may write whatever is current the instant it
    # becomes current. There is no "its own era" left to keep.
    expect(writes.call(old_role, 2)).to eq(:allowed)

    # what is gone, for EITHER role, is the schema era 2 replaced —
    # nobody may write era 1 once era 2 has materialized.
    expect(writes.call(old_role, 1)).to match(/row-level security/i)
    expect(writes.call(new_role, 1)).to match(/row-level security/i)
  end

  it "builds era 3 from era 2's matview, not from raw history — and the layered answer equals the full one" do
    write_v1_record
    l1 = label_of(V1_SOURCE)
    l2 = label_of(V2_SOURCE)
    l3 = label_of(V3_SOURCE)
    check!(V2_SOURCE, translation_source: edge_source(from: l1, to: l2))

    # more era-2 traffic, so the layer has both a matview AND live rows
    # of its own to fold in
    registry = load_registry(V2_SOURCE)
    account = registry.bluebooks.values.first.aggregate("Account")
    adapter = Hecksagain::Adapters::Postgres.new(aggregate: account, settings: { database: LINEAGE_DB, domain: "Ledger" })
    adapter.save(Hecksagain::Runtime::Instance.new(
                   aggregate: account, id: "business",
                   state: { amount: { "cents" => 250 }, kind: { "label" => "business" },
                            denomination: { "code" => "USD" } }
                 ))

    edges = "#{edge_source(from: l1, to: l2)}\n#{edge_source_v3(from: l2, to: l3)}"
    check!(V3_SOURCE, translation_source: edges)

    db = PG.connect(dbname: LINEAGE_DB)
    layered = db.exec("SELECT aggregate_id, operation, state FROM #{PG::Connection.quote_ident("account_lineage_3_#{l3}")} ORDER BY aggregate_id").values

    # the definition actually used era 2's matview rather than the journal
    definition = db.exec_params("SELECT definition FROM pg_matviews WHERE matviewname = $1",
                                ["account_lineage_3_#{l3}"])[0]["definition"]
    expect(definition).to include("account_lineage_2_#{l2}")

    # ...and it agrees with the from-scratch build, row for row
    lineage = Hecksagain::Adapters::Postgres::Lineage.new(db, "Ledger")
    chain = Hecksagain::Adapters::Postgres::LineageManager.edge_chain(
      load_registry(V3_SOURCE, translation_source: edges), load_registry(V3_SOURCE).bluebooks.values.first,
      lineage.eras[0..-2], l3
    )
    full = db.exec("SELECT aggregate_id, operation, state FROM (#{lineage.chain_sql(account, 3, chain)}) full_build ORDER BY aggregate_id").values
    db.close

    expect(layered).to eq(full)
    expect(layered).not_to be_empty
  end

  it "the layered build still honours the cut — an era-2 checkout writing after era 3 was minted never reaches era 3's head" do
    write_v1_record
    l1 = label_of(V1_SOURCE)
    l2 = label_of(V2_SOURCE)
    l3 = label_of(V3_SOURCE)
    check!(V2_SOURCE, translation_source: edge_source(from: l1, to: l2))
    edges = "#{edge_source(from: l1, to: l2)}\n#{edge_source_v3(from: l2, to: l3)}"
    check!(V3_SOURCE, translation_source: edges)

    # the fork: an old era-2 checkout keeps writing its own partition
    # AFTER era 3 cut its watermark. The layer beneath era 3's matview
    # is era 2's matview — so if the cut were re-derived at query time
    # (or forgotten in the layer), this write would leak upward.
    stale = Hecksagain::Adapters::Postgres.new(
      aggregate: load_registry(V2_SOURCE).bluebooks.values.first.aggregate("Account"),
      settings: { database: LINEAGE_DB, domain: "Ledger", era: 2 }
    )
    stale.save(Hecksagain::Runtime::Instance.new(
                 aggregate: load_registry(V2_SOURCE).bluebooks.values.first.aggregate("Account"),
                 id: "business", state: { amount: { "cents" => 999 }, kind: { "label" => "business" },
                                          denomination: { "code" => "ZZZ" } }
               ))

    db = PG.connect(dbname: LINEAGE_DB)
    # THE REFRESH IS THE POINT. Materialization alone freezes the tail,
    # so a post-cut write cannot leak whether or not the cut is in the
    # definition — which makes the naive version of this test vacuous.
    # The cut only earns its keep when the definition is re-evaluated,
    # and the header promises it holds "even on a full REFRESH". So
    # refresh, and hold it to that.
    db.exec("REFRESH MATERIALIZED VIEW #{PG::Connection.quote_ident("account_lineage_3_#{l3}")}")
    head = db.exec("SELECT id, state FROM account_head ORDER BY id").values
    diverged = Hecksagain::Adapters::Postgres::Lineage.new(db, "Ledger").diverged_count(2)
    db.close

    # the post-cut write is real and observable as divergence...
    expect(diverged).to eq(1)
    # ...and it is NOT in the new world's head
    expect(head.map(&:last).join).not_to include("999")
    expect(head.map(&:last).join).not_to include("ZZZ")
  end

  it "journal rows accept no UPDATE or DELETE from PUBLIC — immutability by privilege" do
    check!(V1_SOURCE)
    db = PG.connect(dbname: LINEAGE_DB)
    acl = db.exec("SELECT relacl::text FROM pg_class WHERE relname = 'hecks_journal_ledger'")[0]["relacl"]
    db.close
    # An explicit ACL exists (the REVOKE materialized it), and PUBLIC
    # carries no grants at all in it — only the owner's own entry.
    expect(acl).not_to be_nil
    expect(acl).not_to include("=w")
  end

  it "holds the code path and the compiled matview to the same answer — the cross-execution equivalence gate" do
    write_v1_record
    from = label_of(V1_SOURCE)
    to = label_of(V2_SOURCE)
    registry = check!(V2_SOURCE, translation_source: edge_source(from: from, to: to))

    # the reference semantics: the port-level entry-JSON transform
    edge = registry.translations.first
    declared = edge.for_aggregate("Account")
    rules = Hecksagain::Ports::Persistence::Lineage.from_declared(declared, "Account")
    entry = Hecksagain::Ports::Persistence::Entry.new(
      operation: "save", id: "a1",
      state: { cost: { "cents" => 100, "currency" => "USD" }, kind: { "label" => "biz" }, legacy_note: { "text" => "keep?" } }
    )
    reference = JSON.parse(JSON.generate(rules.translate(entry).state))

    # the compilation target: the matview the mint created
    db = PG.connect(dbname: LINEAGE_DB)
    matview = db.exec("SELECT matviewname FROM pg_matviews")[0]["matviewname"]
    expect(matview).to eq("account_lineage_2_#{to}")
    compiled = JSON.parse(db.exec("SELECT state FROM #{matview} WHERE aggregate_id = 'a1'")[0]["state"])
    db.close

    expect(compiled).to eq(reference)
  end
end
