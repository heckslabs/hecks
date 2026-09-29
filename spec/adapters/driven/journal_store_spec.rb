require "hecks"
require "hecks/ports/persistence/plugins/era"
require "json"
require "open3"
require "tmpdir"
require "fileutils"
require "tempfile"
require_relative "../../support/postgres_probe"
require_relative "../../support/fenced_owner"
require_relative "../../../lib/hecks/hecks/adapters/journal_store"

# The JournalStore port's adapter against a real Postgres: the facts an examination reports, the
# changes an admitted request makes, and the reads that never write. Needs a reachable Postgres.
RSpec.describe Hecks::Adapters::JournalStore, :io do
  JS_DB = "hecks_journal_store_spec".freeze

  JS_V1 = <<~BLUEBOOK.freeze
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

  JS_V2 = <<~BLUEBOOK.freeze
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

  # The same shape change as `JS_V2`, its data carried by a `compute` and a `rekey` that only a
  # rehearsal can vouch for.
  JS_EDGE = <<~RUBY.freeze
    Hecks.data_translation("Ledger", from: %<from>s, to: %<to>s) do
      aggregate("Account", was: "Acct") do
        rename :cost, to: :amount
        move "amount.currency", to: "denomination.code"
        convert "kind.label", to: "kind.label", values: { "biz" => "business", "pers" => "personal" }
        drop :legacy_note
      end
    end
  RUBY

  JS_COMPUTED_EDGE = <<~RUBY.freeze
    Hecks.data_translation("Ledger", from: %<from>s, to: %<to>s) do
      aggregate("Account", was: "Acct") do
        rename :cost, to: :amount
        move "amount.currency", to: "denomination.code"
        drop :legacy_note
        compute "kind", to: "kind", sql: "jsonb_build_object('label', upper(__s -> 'kind' ->> 'label'))"
        rekey sql: "upper(__s -> 'kind' ->> 'label')"
      end
    end
  RUBY

  subject(:store) { described_class.new }

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{JS_DB} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{JS_DB}")
    admin.close
    FencedOwner.own!(JS_DB)
    @root = Dir.mktmpdir("journal-store-")
  end

  after(:all) do
    FileUtils.rm_rf(@root) if @root
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{JS_DB} WITH (FORCE)")
    admin.close
  end

  before do
    scrub = PG.connect(dbname: JS_DB)
    scrub.exec("SET client_min_messages = warning")
    scrub.exec("DROP SCHEMA public CASCADE")
    scrub.exec("CREATE SCHEMA public")
    scrub.close
    FencedOwner.own_public!(JS_DB)
    @domain = File.join(@root, "ledger-#{SecureRandom.hex(4)}")
  end

  def url = FencedOwner.url(JS_DB)

  def load_registry(source)
    registry = Hecks::Runtime::Registry.new
    loading = Hecks::Ports::Loading.bootstrap
    file = Tempfile.new(["journal-store-", ".bluebook"])
    file.write(source)
    file.flush
    Hecks.with_registry(registry) do
      loading.load_library
      Kernel.eval(source, TOPLEVEL_BINDING, file.path, 1)
    end
    registry
  ensure
    file&.close!
  end

  def label_of(source)
    Hecks::Runtime::StorageShape.mint_hash(load_registry(source).bluebooks.values.first)[0, 6]
  end

  # Writes the current domain (`JS_V2`) to disk, with the edge that leads to it when asked.
  def write_domain(edge: nil)
    bluebook = File.join(@domain, "bluebook")
    FileUtils.mkdir_p(File.join(bluebook, "translations"))
    File.write(File.join(bluebook, "ledger.bluebook"), JS_V2)
    File.write(File.join(bluebook, "ledger.hecksagon"),
               "Hecks.hecksagon \"Ledger\" do\n  Ledger::Account.persisted_by(\"PostgresEra\")\nend\n")
    File.write(File.join(bluebook, "ledger.world"),
               "Hecks.world \"Ledger\" do\n  realm \"Specs\"\n  persisted_by(\"PostgresEra\") do\n    " \
               "database #{url.inspect}\n  end\nend\n")
    return unless edge

    from = label_of(JS_V1)
    to = label_of(JS_V2)
    File.write(File.join(bluebook, "translations", "2-#{to}.bluebook"), format(edge, from: from.inspect, to: to.inspect))
    File.join(bluebook, "translations")
  end

  # Holds era 1 from `JS_V1`, as a first boot of the old checkout does, and saves one record.
  def hold_v1_with_a_record
    registry = load_registry(JS_V1)
    bluebook = registry.bluebooks.values.first
    Hecks::Adapters::PostgresEra::LineageManager.check!(
      registry: registry, bluebook: bluebook, current_text: JS_V1, settings: { database: url }
    )
    adapter = Hecks::Adapters::PostgresEra.new(aggregate: bluebook.aggregate("Acct"),
                                               settings:  { database: url, domain: "Ledger" })
    adapter.save(Hecks::Runtime::Instance.new(
                   aggregate: bluebook.aggregate("Acct"), id: "a1",
                   state: { cost: { "cents" => 100, "currency" => "USD" }, kind: { "label" => "biz" },
                            legacy_note: { "text" => "keep?" } }
                 ))
    registry
  end

  def sql(statement, *params)
    db = PG.connect(dbname: JS_DB)
    db.exec_params(statement, params).to_a
  ensure
    db&.close
  end

  def request(operation, **fields)
    { operation: { value: operation }, domain: { value: @domain } }.merge(fields)
  end

  def facts(operation, **fields)
    store.examine(**request(operation, **fields)).transform_values { |fact| fact[:value] }
  end

  describe "reading" do
    before { write_domain }

    it "answers that no era is held and changes nothing, however often it is asked" do
      expect(store.scaffold_translation(domain: { value: @domain })).to include("holds no era yet")
      expect(store.audit_translation(domain: { value: @domain })).to include("hecks hold_first")
      expect(sql("SELECT to_regclass('hecks_eras') AS present").first["present"]).to be_nil
    end

    it "holds era 1 only when HoldFirst is applied, once" do
      expect(facts("hold_first")).to include(capable: true, held: 0)

      expect(store.apply(**request("hold_first")).dig(:report, :value)).to eq("Ledger holds era 1 now.")

      expect(sql("SELECT ordinal, held_text FROM hecks_eras WHERE domain = 'Ledger'"))
        .to eq([{ "ordinal" => "1", "held_text" => JS_V2 }])
      expect(facts("hold_first")).to include(held: 1)
      expect { store.apply(**request("hold_first")) }.to raise_error(Hecks::Runtime::WiringError, /already holds an era/)
    end
  end

  describe "scaffolding and auditing the edge from era 1" do
    before { hold_v1_with_a_record }

    it "scaffolds the edge as text and writes no file" do
      write_domain
      text = store.scaffold_translation(domain: { value: @domain })

      expect(text).to include("# Save as translations/2-#{label_of(JS_V2)}.bluebook.")
      expect(text).to include("Hecks.data_translation \"Ledger\", from: #{label_of(JS_V1).inspect}")
      expect(Dir[File.join(@domain, "bluebook", "translations", "*")]).to be_empty
      expect(sql("SELECT hash FROM hecks_eras WHERE ordinal = 1").first["hash"]).to be_nil
    end

    it "audits the pending edge without naming era 1" do
      write_domain(edge: JS_EDGE)
      report = store.audit_translation(domain: { value: @domain })

      expect(report).to include("Ledger::Account (edge #{label_of(JS_V1)} → #{label_of(JS_V2)}, 1 record)")
      expect(report).to include("AUDIT PASSED — review the samples above")
      expect(sql("SELECT hash FROM hecks_eras WHERE ordinal = 1").first["hash"]).to be_nil
    end

    it "refuses an audit when no edge leads to the current shape" do
      write_domain

      expect { store.audit_translation(domain: { value: @domain }) }
        .to raise_error(Hecks::Runtime::NotFound, /no translation edge leads/)
    end
  end

  describe "approving an edge in a committed file" do
    before do
      Open3.capture2e("git", "init", "-q", @domain.tap { |path| FileUtils.mkdir_p(path) })
      Open3.capture2e("git", "-C", @domain, "config", "user.name", "Ada Lovelace")
      Open3.capture2e("git", "-C", @domain, "config", "user.email", "ada@example.com")
      hold_v1_with_a_record
    end

    it "reports the facts an edge without a compute or rekey needs, and writes the file" do
      write_domain(edge: JS_EDGE)

      expect(facts("approve_translation")).to include(
        capable: true, edges: 1, audited: true, rehearsal_needed: false
      )
      report = store.apply(**request("approve_translation")).dig(:report, :value)
      path = File.join(@domain, "bluebook", "translations", "#{label_of(JS_V1)}-#{label_of(JS_V2)}.approval")

      expect(report).to include(path)
      document = JSON.parse(File.read(path))
      expect(document.keys).to eq(%w[edge edge_digest approved_by approved_at])
      expect(document).to include("edge"        => "#{label_of(JS_V1)}-#{label_of(JS_V2)}",
                                  "approved_by" => "Ada Lovelace <ada@example.com>")
      expect(document["approved_at"]).to match(/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T/)
    end

    it "asks a rehearsal of an edge with a compute or rekey, and applies the committed file at the mint" do
      write_domain(edge: JS_COMPUTED_EDGE)
      rehearsal = { snapshot: { value: "rds:ledger-2026-09-28" }, host_version: { value: "3.0.0" },
                    rehearsal: { value: "pass" }, rehearsed_at: { value: "2026-09-28T12:00:00Z" } }

      expect(facts("approve_translation")).to include(rehearsal_needed: true, rehearsal_recorded: false)
      expect { store.apply(**request("approve_translation")) }
        .to raise_error(ArgumentError, /approved on a rehearsal that passed/)
      expect(facts("approve_translation", **rehearsal)).to include(rehearsal_recorded: true)
      expect(facts("approve_translation", **rehearsal, rehearsal: { value: "fail" }))
        .to include(rehearsal_recorded: false)

      store.apply(**request("approve_translation", **rehearsal))

      expect(mint_v2.resolved_eras["Ledger"]).to eq(2)
      expect(sql("SELECT edge_digest FROM hecks_approvals").size).to eq(1)
    end

    it "does not mint on a committed approval whose edge changed since" do
      write_domain(edge: JS_COMPUTED_EDGE)
      rehearsal = { snapshot: { value: "rds:x" }, host_version: { value: "3.0.0" },
                    rehearsal: { value: "pass" }, rehearsed_at: { value: "2026-09-28T12:00:00Z" } }
      store.apply(**request("approve_translation", **rehearsal))
      to = label_of(JS_V2)
      edge_path = File.join(@domain, "bluebook", "translations", "2-#{to}.bluebook")
      File.write(edge_path, File.read(edge_path).sub("upper(", "lower("))

      expect { mint_v2 }.to raise_error(Hecks::Runtime::WiringError, /human-approved sample is its only verification/)
    end

    # Boots the current shape the way the host does, edges and committed approvals from disk.
    def mint_v2
      directory = File.join(@domain, "bluebook")
      registry = Hecks::Runtime::Registry.new
      loading = Hecks::Ports::Loading.bootstrap
      Hecks.with_registry(registry) do
        loading.load_library
        loading.load_domain(directory)
      end
      Hecks::Adapters::PostgresEra::LineageManager.check!(
        registry: registry, bluebook: registry.bluebooks.values.first, current_text: JS_V2,
        settings: { database: url }, directory: directory
      )
      registry
    end
  end

  describe "re-attesting a held text" do
    before do
      hold_v1_with_a_record
      write_domain
    end

    let(:edited) { "# a comment added by hand\n#{JS_V1}" }

    it "reads the text back and attests to it only once admitted" do
      sql("UPDATE hecks_eras SET held_text = $1 WHERE ordinal = 1", edited)

      shown = store.attestation(domain: { value: @domain }, era: { value: 1 })
      expect(shown).to include("does NOT match its recorded digest", "# a comment added by hand", "shape:    unchanged")
      expect(facts("reattest", era: { value: 1 })).to include(capable: true)

      report = store.apply(**request("reattest", era: { value: 1 })).dig(:report, :value)

      expect(report).to start_with("ATTESTED: era 1 re-frozen as ")
      expect(sql("SELECT count(*)::int AS n FROM hecks_attestations").first["n"].to_i).to eq(1)
      expect(store.attestation(domain: { value: @domain }, era: { value: 1 })).to include("nothing to re-attest")
    end

    it "refuses an edit that changed the era's shape, whatever was confirmed" do
      sql("UPDATE hecks_eras SET held_text = $1 WHERE ordinal = 1", JS_V2)

      expect { store.apply(**request("reattest", era: { value: 1 })) }
        .to raise_error(Hecks::Runtime::WiringError, /changed the era's SHAPE/)
      expect { store.attestation(domain: { value: @domain }, era: { value: 1 }) }
        .to raise_error(Hecks::Runtime::NotFound, /changed the era's SHAPE/)
    end

    it "refuses an era that is not held" do
      expect { facts("reattest", era: { value: 7 }) }.to raise_error(Hecks::Runtime::NotFound, /holds no era 7/)
    end
  end

  describe "backfilling projections" do
    it "stores the shape for the eras that predate it, and says so when there is nothing to do" do
      write_domain
      hold_v1_with_a_record
      sql("UPDATE hecks_eras SET held_projection = NULL WHERE ordinal = 1")

      first = store.apply(**request("backfill_projections")).dig(:report, :value)
      second = store.apply(**request("backfill_projections")).dig(:report, :value)

      expect(sql("SELECT held_projection IS NOT NULL AS held FROM hecks_eras").first["held"]).to eq("t")
      expect(first).to include("backfilled 1 era")
      expect(second).to include("nothing to do")
    end
  end

  describe "merging the tail" do
    # An old checkout keeps writing era 1 after era 2 was minted: `a1` in both worlds, `a9` in one.
    def fork_worlds
      hold_v1_with_a_record
      write_domain(edge: JS_EDGE)
      directory = File.join(@domain, "bluebook")
      registry = Hecks::Runtime::Registry.new
      loading = Hecks::Ports::Loading.bootstrap
      Hecks.with_registry(registry) do
        loading.load_library
        loading.load_domain(directory)
      end
      bluebook = registry.bluebooks.values.first
      Hecks::Adapters::PostgresEra::LineageManager.check!(
        registry: registry, bluebook: bluebook, current_text: JS_V2, settings: { database: url }, directory: directory
      )
      account = bluebook.aggregate("Account")
      Hecks::Adapters::PostgresEra.new(aggregate: account, settings: { database: url, domain: "Ledger", era: 2 })
                                  .save(Hecks::Runtime::Instance.new(
                                          aggregate: account, id: "a1",
                                          state: { amount: { "cents" => 999 }, kind: { "label" => "business" },
                                                   denomination: { "code" => "USD" }, status: "open" }
                                        ))
      old_write("a1", 111)
      old_write("a9", 5)
    end

    def old_write(id, cents)
      state = JSON.generate(cost: { "cents" => cents, "currency" => "USD" }, kind: { "label" => "biz" },
                            legacy_note: { "text" => "late" })
      ordinal = sql("INSERT INTO hecks_journal_ledger (era, aggregate, aggregate_id, operation, state) " \
                    "VALUES (1, 'acct', $1, 'save', $2) RETURNING ordinal", id, state).first["ordinal"]
      sql("INSERT INTO ledger_acct_head_snapshot_1 (id, ordinal, state) VALUES ($1, $2, $3) " \
          "ON CONFLICT (id) DO UPDATE SET ordinal = $2, state = $3", id, ordinal, state)
    end

    it "reports the records both worlds touched that have no winner, then merges once each has one" do
      fork_worlds

      expect(facts("merge_tail")).to include(capable: true, held: 2, forks: 0, contested: 1)
      expect(facts("merge_tail", winners: { value: "a1:new" })).to include(contested: 0)

      report = store.apply(**request("merge_tail", winners: { value: "a1:new" })).dig(:report, :value)

      expect(report).to include("2 post-cut writes in ancestor eras before the merge", "winner a1=new appended")
      expect(sql("SELECT state FROM ledger_account_head WHERE id = 'a1'").first["state"])
        .to include('"cents": 999')
    end

    it "keeps the database's own refusal when a winner is missing" do
      fork_worlds

      expect { store.apply(**request("merge_tail")) }
        .to raise_error(Hecks::Runtime::WiringError, /touched by both worlds since the cut — account#a1/)
    end

    it "finds nothing to merge at era 1" do
      hold_v1_with_a_record
      write_domain(edge: JS_EDGE)

      expect(facts("merge_tail")).to include(capable: true, held: 1)
    end
  end

  describe "through the launcher" do
    def run_verb(*argv)
      @hecks ||= Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_facade: false)
      Hecks::Facade::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")
    end

    it "holds the first era when confirmed, and refuses a merge before a second exists" do
      write_domain(edge: JS_EDGE)

      run_verb("hold_first", @domain, "run=first-1", "--confirm")
      row = JSON.parse(run_verb("settlement", "first-1").first).first
      expect([row.fetch("status"), row.dig("report", "value")]).to eq(["settled", "Ledger holds era 1 now."])

      out, = run_verb("merge_tail", @domain, "run=merge-1", "--confirm")
      expect(JSON.parse(out).fetch("refused_reactions").first.fetch("reason"))
        .to eq("Admit refused — an era beyond the first stands before a tail is merged")

      again, = run_verb("hold_first", @domain, "run=first-2", "--confirm")
      expect(JSON.parse(again).fetch("refused_reactions").first.fetch("reason"))
        .to eq("Admit refused — no era is held yet")
    end

    it "words the store-keeps-eras rule for a domain on Memory" do
      write_domain
      File.write(File.join(@domain, "bluebook", "ledger.hecksagon"),
                 "Hecks.hecksagon \"Ledger\" do\n  Ledger::Account.persisted_by(\"Memory\")\nend\n")
      File.delete(File.join(@domain, "bluebook", "ledger.world"))

      out, = run_verb("backfill_projections", @domain, "run=backfill-1")

      expect(JSON.parse(out).fetch("refused_reactions").first.fetch("reason"))
        .to eq("Admit refused — the store keeps eras")
    end
  end

  describe "a domain whose store keeps no eras" do
    it "reports that it is not capable, for the store-keeps-eras rule to refuse" do
      write_domain
      File.write(File.join(@domain, "bluebook", "ledger.hecksagon"),
                 "Hecks.hecksagon \"Ledger\" do\n  Ledger::Account.persisted_by(\"Memory\")\nend\n")
      File.delete(File.join(@domain, "bluebook", "ledger.world"))

      expect(facts("hold_first")).to include(capable: false)
      expect { store.scaffold_translation(domain: { value: @domain }) }
        .to raise_error(Hecks::Runtime::NotFound, /Memory, which holds no eras/)
    end
  end
end
