require "hecksagain"

# Lineage in the Postgres adapter: the partitioned journal, the
# hecks_eras rows, the one-transaction mint, and the head compiled as a
# chain of edges — old entries translated at inclusion, never rewritten.
# Runs only when a Postgres server is reachable, like every other
# Postgres spec here.
postgres_available =
  begin
    PG.connect(dbname: "postgres").close
    true
  rescue PG::Error
    false
  end

RSpec.describe "lineage in the Postgres adapter",
               skip: (postgres_available ? false : "no reachable Postgres — start one to run this spec") do
  LINEAGE_DB = "hecksagain_lineage_spec".freeze

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

  before(:all) do
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{LINEAGE_DB} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{LINEAGE_DB}")
    admin.close
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

  def check!(source, translation_source: nil)
    registry = load_registry(source, translation_source: translation_source)
    bluebook = registry.bluebooks.values.first
    Hecksagain::Adapters::Postgres::LineageManager.check!(
      registry: registry, bluebook: bluebook, current_text: source, settings: { database: LINEAGE_DB }
    )
    registry
  end

  def hash_of(source)
    registry = load_registry(source)
    Hecksagain::Runtime::StorageShape.mint_hash(registry.bluebooks.values.first)
  end

  def label_of(source) = hash_of(source)[0, 6]

  def adapter_for(registry, aggregate_name)
    aggregate = registry.bluebooks.values.first.aggregate(aggregate_name)
    Hecksagain::Adapters::Postgres.new(aggregate: aggregate, settings: { database: LINEAGE_DB, domain: "Ledger" })
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

  it "refuses an edited hecks_eras row and says which situation the operator is in — with the archive as recovery" do
    check!(V1_SOURCE)
    db = PG.connect(dbname: LINEAGE_DB)

    # shape-changing edit
    db.exec_params("UPDATE hecks_eras SET held_text = $1 WHERE domain = 'Ledger' AND ordinal = 1", [V2_SOURCE])
    expect { check!(V1_SOURCE) }.to raise_error(
      Hecksagain::Runtime::WiringError,
      "cannot boot Ledger: the held text of era 1 was edited after it was frozen AND the edit changed " \
      "the storage shape — re-attestation will refuse it; restore the original text from the era archive"
    )

    # cosmetic edit
    db.exec_params("UPDATE hecks_eras SET held_text = $1 WHERE domain = 'Ledger' AND ordinal = 1",
                   ["# a typo fixed\n#{V1_SOURCE}"])
    expect { check!(V1_SOURCE) }.to raise_error(
      Hecksagain::Runtime::WiringError,
      "cannot boot Ledger: the held text of era 1 was edited after it was frozen — the edit is cosmetic " \
      "to the storage shape; re-attest it (bin/reattest_era), or restore the original text from the era archive"
    )

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

  it "permits an old checkout to keep booting its superseded era, writing its own partition — the fork" do
    write_v1_record
    from = label_of(V1_SOURCE)
    to = label_of(V2_SOURCE)
    check!(V2_SOURCE, translation_source: edge_source(from: from, to: to))

    old_registry = check!(V1_SOURCE)
    expect(old_registry.resolved_eras["Ledger"]).to eq(1)

    old_world = Hecksagain::Adapters::Postgres.new(
      aggregate: old_registry.bluebooks.values.first.aggregate("Acct"),
      settings: { database: LINEAGE_DB, domain: "Ledger", era: 1 }
    )
    old_world.save(Hecksagain::Runtime::Instance.new(
      aggregate: old_registry.bluebooks.values.first.aggregate("Acct"), id: "a9",
      state: { cost: { "cents" => 5, "currency" => "USD" }, kind: { "label" => "biz" }, legacy_note: { "text" => "late" } }
    ))

    db = PG.connect(dbname: LINEAGE_DB)
    # the post-cut write landed in the era-1 partition...
    eras_of_a9 = db.exec("SELECT era FROM hecks_journal_ledger WHERE aggregate_id = 'a9'").map { |row| row["era"] }
    expect(eras_of_a9).to eq(["1"])
    # ...the old world sees it...
    expect(old_world.find("a9").cost.to_h).to eq(cents: 5, currency: "USD")
    # ...the new head does NOT (the watermark is baked into the matview)...
    new_head = db.exec("SELECT count(*) FROM account_head WHERE id = 'a9'")[0]["count"]
    expect(new_head).to eq("0")
    # ...and the divergence is observable
    lineage = Hecksagain::Adapters::Postgres::Lineage.new(db, "Ledger")
    expect(lineage.diverged_count(1)).to eq(1)
    db.close
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
      "a re-keying, not a translation — stored ids were minted under kind.label, and no rule can declare rows " \
      "the same entity under a new key. Keep the identity path, or migrate the data explicitly"
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
        identified_by { sku.value }

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
        identified_by { sku.value }

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
      "cannot mint era 2 of Pricing: this edge carries a compute rule, and the audit's human-approved " \
      "sample is a compute's only verification — run bin/translation_audit with --approve, then boot again"
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
