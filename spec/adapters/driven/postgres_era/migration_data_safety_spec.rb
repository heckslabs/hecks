require "hecks"
require "hecks/ports/persistence/plugins/era"
require "tempfile"
require_relative "../../../support/postgres_probe"
require_relative "../../../support/fenced_owner"

# The three data-loss defects the 2026-08-10 audit found in PostgresEra's
# migration path, each pinned against a real Postgres. A migration that
# loses or resurrects a record, or mints under an approval that no longer
# describes it, does damage nothing else notices, so each fix is held here
# by a spec that fails without it.
#
# - **H3, era-migrated deletes.** A delete of a record carried in from an
#   ancestor era writes a tombstone row (`operation = 'delete'`) that
#   outranks the ancestor's save row, so the record stays deleted. The
#   one-mint case lives in `lineage_spec.rb` ("deleting an era-migrated
#   record does not resurrect the ancestor era's save row"); this file adds
#   the case across two mints, where era 3's head is built on era 2's.
# - **H4, the rekey digest.** A compute or rekey edge mints only under a
#   recorded human approval bound to the edge's digest. The digest covers a
#   rekey's SQL and a backfill's default; editing either after approval must
#   refuse the mint, and the old approval must still mint the edge it
#   approved. `spec/exporter_spec.rb` pins the digest itself with no
#   database; this file pins what a mint does with it.
# - **H5, dotted computes.** A compute owning `price.cents` exempts that one
#   member from Layer 2's reference-transform comparison, never its sibling
#   `price.currency`. `layer_two_spec.rb` pins `strip_compute_paths` with
#   hand-built rows. This file feeds the audit the rows a real compiled
#   head produces: a dotted compute that only writes its own member mints,
#   and a compiled edge that also loses a sibling is refused.
#
# Every example runs against a disposable database owned here and connects
# as a non-superuser owner (`FencedOwner`), the way a deployment boots
# PostgresEra. Under `CI`, an unreachable Postgres fails the group instead of
# skipping it (`PostgresProbe`), and this file is in
# `.github/postgres_io_spec_files.txt`, so a leg that provisions Postgres
# always runs it.
RSpec.describe "PostgresEra migration data safety", :io do
  DATA_SAFETY_DB = "hecks_era_data_safety_spec".freeze

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{DATA_SAFETY_DB} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{DATA_SAFETY_DB}")
    admin.close
    FencedOwner.own!(DATA_SAFETY_DB)
  end

  after(:all) do
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{DATA_SAFETY_DB} WITH (FORCE)")
    admin.close
  end

  before do
    scrub = PG.connect(dbname: DATA_SAFETY_DB)
    scrub.exec("DROP SCHEMA public CASCADE")
    scrub.exec("CREATE SCHEMA public")
    scrub.close
    FencedOwner.own_public!(DATA_SAFETY_DB)
  end

  def lineage_manager = Hecks::Adapters::PostgresEra::LineageManager

  def load_registry(source, translation_source: nil)
    registry = Hecks::Runtime::Registry.new
    loading = Hecks::Ports::Loading.bootstrap
    file = Tempfile.new(["data-safety-", ".bluebook"])
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

  def check!(source, translation_source: nil)
    registry = load_registry(source, translation_source: translation_source)
    lineage_manager.check!(
      registry: registry, bluebook: registry.bluebooks.values.first,
      current_text: source, settings: { database: FencedOwner.url(DATA_SAFETY_DB) }
    )
    registry
  end

  def label_of(source)
    Hecks::Runtime::StorageShape.mint_hash(load_registry(source).bluebooks.values.first)[0, 6]
  end

  def head_for(registry, aggregate_name, domain)
    aggregate = registry.bluebooks.values.first.aggregate(aggregate_name)
    Hecks::Adapters::PostgresEra.new(aggregate: aggregate, settings: { database: DATA_SAFETY_DB, domain: domain })
  end

  def instance_of(registry, aggregate_name, id, state)
    aggregate = registry.bluebooks.values.first.aggregate(aggregate_name)
    Hecks::Runtime::Instance.new(aggregate: aggregate, id: id, state: state)
  end

  def with_db
    db = PG.connect(dbname: DATA_SAFETY_DB)
    yield db
  ensure
    db&.close
  end

  def era_count(domain)
    with_db { |db| db.exec_params("SELECT count(*) FROM hecks_eras WHERE domain = $1", [domain])[0]["count"].to_i }
  end

  # Records the human approval `bin/translation_audit --approve` would, for exactly this edge.
  def approve!(domain, registry)
    edge = registry.translations.first
    with_db do |db|
      Hecks::Adapters::PostgresEra::Lineage.new(db, domain).record_approval!(
        from: edge.from, to: edge.to, edge_digest: Hecks::Translation::Audit.edge_digest(edge)
      )
    end
  end

  # ── H3 ────────────────────────────────────────────────────────────────

  describe "H3 — a delete of an era-migrated record stays deleted across two mints" do
    # An `Acct` whose one free-text attribute is spelled `attribute_name`; each era renames it.
    def ledger_source(attribute_name, value_object_name)
      <<~BLUEBOOK
        Hecks.bluebook "Ledger" do
          aggregate "Acct" do
            identified_by :ref

            attribute :ref, Ref
            attribute :#{attribute_name}, #{value_object_name}

            value_object "Ref" do
              attribute :value, String
            end

            value_object "#{value_object_name}" do
              attribute :text, String
            end
          end
        end
      BLUEBOOK
    end

    let(:first_era) { ledger_source("note", "Note") }
    let(:second_era) { ledger_source("memo", "Memo") }
    let(:third_era) { ledger_source("remark", "Remark") }

    def edge(from, to, renamed_from, renamed_to)
      <<~RUBY
        Hecks.data_translation("Ledger", from: #{from.inspect}, to: #{to.inspect}) do
          aggregate("Acct") do
            rename :#{renamed_from}, to: :#{renamed_to}
          end
        end
      RUBY
    end

    def edges
      l1 = label_of(first_era)
      l2 = label_of(second_era)
      l3 = label_of(third_era)
      [edge(l1, l2, "note", "memo"), edge(l2, l3, "memo", "remark")]
    end

    def seed_era_one!
      registry = check!(first_era)
      head = head_for(registry, "Acct", "Ledger")
      %w[keep gone].each do |id|
        head.save(instance_of(registry, "Acct", id, ref: { "value" => id }, note: { "text" => "n-#{id}" }))
      end
    end

    it "keeps a record deleted in era 2 deleted in era 3, whose head is built on era 2's" do
      seed_era_one!
      registry2 = check!(second_era, translation_source: edges[0])
      head2 = head_for(registry2, "Acct", "Ledger")
      expect(head2.find("gone")).not_to be_nil # carried across the first mint
      head2.delete("gone")

      registry3 = check!(third_era, translation_source: edges.join("\n"))
      head3 = head_for(registry3, "Acct", "Ledger")

      expect(head3.find("gone")).to be_nil
      expect(head3.all.map(&:id)).to eq(%w[keep])
      expect(head3.count).to eq(1)
    end

    it "keeps a record deleted in era 3 deleted, though eras 1 and 2 still hold a save row for it" do
      seed_era_one!
      check!(second_era, translation_source: edges[0])
      registry3 = check!(third_era, translation_source: edges.join("\n"))
      head3 = head_for(registry3, "Acct", "Ledger")
      expect(head3.find("gone")).not_to be_nil
      head3.delete("gone")

      expect(head3.find("gone")).to be_nil
      expect(head_for(registry3, "Acct", "Ledger").find("gone")).to be_nil # a fresh boot's own head
      expect(head3.all.map(&:id)).to eq(%w[keep])
    end
  end

  # ── H4 ────────────────────────────────────────────────────────────────

  describe "H4 — an approval binds to the rekey and backfill the human reviewed" do
    DATA_SAFETY_ROSTER_ONE = <<~BLUEBOOK.freeze
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

    DATA_SAFETY_ROSTER_TWO = <<~BLUEBOOK.freeze
      Hecks.bluebook "Roster" do
        aggregate "Person" do
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

    DATA_SAFETY_APPROVED_EMAIL = "chris@example.com".freeze

    def roster_edge(rekeyed_to: DATA_SAFETY_APPROVED_EMAIL, backfilled_to: DATA_SAFETY_APPROVED_EMAIL)
      <<~RUBY
        Hecks.data_translation("Roster", from: #{label_of(DATA_SAFETY_ROSTER_ONE).inspect}, to: #{label_of(DATA_SAFETY_ROSTER_TWO).inspect}) do
          aggregate("Person") do
            rekey sql: "CASE ((__s -> 'name') ->> 'value') WHEN 'Chris Young' THEN '#{rekeyed_to}' END"
            backfill :email, default: "#{backfilled_to}"
          end
        end
      RUBY
    end

    def seed_roster!
      registry = check!(DATA_SAFETY_ROSTER_ONE)
      head_for(registry, "Person", "Roster").save(
        instance_of(registry, "Person", "Chris Young", name: { "value" => "Chris Young" }, title: { "value" => "CEO" })
      )
    end

    def mint_roster!(edge)
      check!(DATA_SAFETY_ROSTER_TWO, translation_source: edge)
    end

    def refusal = /this edge carries a compute or rekey rule, and the audit's human-approved sample is its only verification/

    it "refuses a mint whose rekey SQL was edited after approval, and mints nothing" do
      seed_roster!
      approve!("Roster", load_registry(DATA_SAFETY_ROSTER_TWO, translation_source: roster_edge))

      expect { mint_roster!(roster_edge(rekeyed_to: "someone-else@example.com")) }
        .to raise_error(Hecks::Runtime::WiringError, refusal)
      expect(era_count("Roster")).to eq(1)
    end

    it "refuses a mint whose backfill default was edited after approval, and mints nothing" do
      seed_roster!
      approve!("Roster", load_registry(DATA_SAFETY_ROSTER_TWO, translation_source: roster_edge))

      expect { mint_roster!(roster_edge(backfilled_to: "someone-else@example.com")) }
        .to raise_error(Hecks::Runtime::WiringError, refusal)
      expect(era_count("Roster")).to eq(1)
    end

    it "still mints the edge that was approved, and serves the record under the approved identity" do
      seed_roster!
      approved = roster_edge
      approve!("Roster", load_registry(DATA_SAFETY_ROSTER_TWO, translation_source: approved))
      expect { mint_roster!(roster_edge(rekeyed_to: "someone-else@example.com")) }
        .to raise_error(Hecks::Runtime::WiringError, refusal)

      registry = mint_roster!(approved)

      expect(era_count("Roster")).to eq(2)
      expect(head_for(registry, "Person", "Roster").find(DATA_SAFETY_APPROVED_EMAIL)).not_to be_nil
      expect(head_for(registry, "Person", "Roster").find("someone-else@example.com")).to be_nil
    end
  end

  # ── H5 ────────────────────────────────────────────────────────────────

  describe "H5 — a dotted compute exempts only the member it owns" do
    DATA_SAFETY_PRICING_ONE = <<~BLUEBOOK.freeze
      Hecks.bluebook "Pricing" do
        aggregate "Quote" do
          identified_by :sku

          attribute :sku, Sku
          attribute :price_cents, Cents
          attribute :price, Price

          value_object "Sku" do
            attribute :value, String
          end

          value_object "Cents" do
            attribute :value, Integer
          end

          value_object "Price" do
            attribute :currency, String
          end
        end
      end
    BLUEBOOK

    DATA_SAFETY_PRICING_TWO = <<~BLUEBOOK.freeze
      Hecks.bluebook "Pricing" do
        aggregate "Quote" do
          identified_by :sku

          attribute :sku, Sku
          attribute :price, Price

          value_object "Sku" do
            attribute :value, String
          end

          value_object "Price" do
            attribute :cents, Float
            attribute :currency, String
          end
        end
      end
    BLUEBOOK

    DATA_SAFETY_DOLLARS = "(price_cents::jsonb ->> 'value')::numeric / 100".freeze

    # A compute whose destination is the dotted member `price.cents`: writes that member and
    # leaves `price.currency` alone.
    def narrow_edge
      pricing_edge("price.cents", DATA_SAFETY_DOLLARS)
    end

    # A compute whose destination is the whole `price` value, replacing it: the compiled SQL
    # drops `price.currency`.
    def wide_edge
      pricing_edge("price", "jsonb_build_object('cents', #{DATA_SAFETY_DOLLARS})")
    end

    def pricing_edge(destination, sql)
      <<~RUBY
        Hecks.data_translation("Pricing", from: #{label_of(DATA_SAFETY_PRICING_ONE).inspect}, to: #{label_of(DATA_SAFETY_PRICING_TWO).inspect}) do
          aggregate("Quote") do
            compute "price_cents", to: #{destination.inspect}, sql: #{sql.inspect}
          end
        end
      RUBY
    end

    def seed_quotes!
      registry = check!(DATA_SAFETY_PRICING_ONE)
      head = head_for(registry, "Quote", "Pricing")
      { "q1" => 1250, "q2" => 300 }.each do |sku, cents|
        head.save(instance_of(registry, "Quote", sku, sku: { "value" => sku }, price_cents: { "value" => cents },
                                                      price: { "currency" => "USD" }))
      end
    end

    # Runs the mint-time audit (`CoverageCheck#audit!`) for `compiled`'s SQL, judged against
    # `declared`'s rules, over the journal as it stands.
    def audit(compiled:, declared:)
      compiled_registry = load_registry(DATA_SAFETY_PRICING_TWO, translation_source: compiled)
      declared_registry = load_registry(DATA_SAFETY_PRICING_TWO, translation_source: declared)
      with_db do |db|
        lineage_manager.audit!(
          declared_registry.bluebooks.values.first, Hecks::Adapters::PostgresEra::Lineage.new(db, "Pricing"),
          [{ translation: compiled_registry.translations.first }], 2, declared_registry.translations.first
        )
      end
    end

    it "mints a dotted-destination compute that writes only its own member, keeping the sibling" do
      seed_quotes!
      approve!("Pricing", load_registry(DATA_SAFETY_PRICING_TWO, translation_source: narrow_edge))

      registry = check!(DATA_SAFETY_PRICING_TWO, translation_source: narrow_edge)

      quote = head_for(registry, "Quote", "Pricing").find("q1")
      expect(quote.price.to_h).to eq(cents: 12.5, currency: "USD")
    end

    it "audits clean when the compiled SQL and the declared rules agree" do
      seed_quotes!

      expect { audit(compiled: narrow_edge, declared: narrow_edge) }.not_to raise_error
    end

    it "refuses a mint whose compiled SQL loses the sibling member the dotted compute does not own" do
      seed_quotes!

      expect { audit(compiled: wide_edge, declared: narrow_edge) }.to raise_error(
        Hecks::Runtime::WiringError,
        /the audit refused.*Quote#q1: the translated state diverges from the reference transform at price/m
      )
    end

    DATA_SAFETY_DOTTED_ONE = DATA_SAFETY_PRICING_TWO.sub("attribute :cents, Float", "attribute :cents, Integer").freeze

    # A compute whose source is the dotted member itself. The compiled SQL tests for the source
    # with `__s ? 'price.cents'`, which asks for a top-level key of that literal name, so it
    # never fires and the record is served with the old, unconverted value.
    it "applies the SQL of a compute whose source is a dotted member" do
      pending "open: compile_compute never fires for a dotted source, so the value is carried through unchanged"

      registry = check!(DATA_SAFETY_DOTTED_ONE)
      head_for(registry, "Quote", "Pricing").save(
        instance_of(registry, "Quote", "q1", sku: { "value" => "q1" }, price: { "cents" => 1250, "currency" => "USD" })
      )
      edge = <<~RUBY
        Hecks.data_translation("Pricing", from: #{label_of(DATA_SAFETY_DOTTED_ONE).inspect}, to: #{label_of(DATA_SAFETY_PRICING_TWO).inspect}) do
          aggregate("Quote") do
            compute "price.cents", to: "price.cents", sql: "(__s -> 'price' ->> 'cents')::numeric / 100"
          end
        end
      RUBY
      approve!("Pricing", load_registry(DATA_SAFETY_PRICING_TWO, translation_source: edge))

      minted = check!(DATA_SAFETY_PRICING_TWO, translation_source: edge)

      expect(head_for(minted, "Quote", "Pricing").find("q1").price.to_h).to eq(cents: 12.5, currency: "USD")
    end
  end
end
