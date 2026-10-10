require "hecks"
require "hecks/ports/persistence/plugins/era"
require "json"
require "open3"
require "tmpdir"
require "fileutils"
require_relative "../../support/postgres_probe"
require_relative "../../support/fenced_owner"
require_relative "../../support/era_registry_loading"
require_relative "../../../lib/hecks/hecks/adapters/journal_store"

# The JournalStore port's adapter against a real Postgres: the facts an examination reports, the
# changes an admitted request makes, and the reads that never write. Needs a reachable Postgres.
RSpec.describe Hecks::Adapters::JournalStore, :io do
  include EraRegistryLoading

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

  def label_of(source)
    Hecks::Runtime::StorageShape.mint_hash(load_registry(source).bluebooks.values.first)[0, 6]
  end

  def bluebook_dir = File.join(@domain, "bluebook")

  def memory_hecksagon = "Hecks.hecksagon \"Ledger\" do\n  Ledger::Account.persisted_by(\"Memory\")\nend\n"

  # Writes the current domain (`JS_V2`) to disk, with the edge that leads to it when asked.
  def write_domain(edge: nil)
    write_domain_files
    write_edge(edge) if edge
  end

  def write_domain_files
    FileUtils.mkdir_p(File.join(bluebook_dir, "translations"))
    File.write(File.join(bluebook_dir, "ledger.bluebook"), JS_V2)
    File.write(File.join(bluebook_dir, "ledger.hecksagon"),
               "Hecks.hecksagon \"Ledger\" do\n  Ledger::Account.persisted_by(\"PostgresEra\")\nend\n")
    File.write(File.join(bluebook_dir, "ledger.world"),
               "Hecks.world \"Ledger\" do\n  realm \"Specs\"\n  persisted_by(\"PostgresEra\") do\n    " \
               "database #{url.inspect}\n  end\nend\n")
  end

  # Writes the edge from era 1 to the current shape; answers the translations directory.
  def write_edge(edge)
    to = label_of(JS_V2)
    translations = File.join(bluebook_dir, "translations")
    File.write(File.join(translations, "2-#{to}.bluebook"), format(edge, from: label_of(JS_V1).inspect, to: to.inspect))
    translations
  end

  # A domain whose store keeps no eras: the same files, bound to Memory with no world.
  def make_memory_domain
    write_domain
    File.write(File.join(bluebook_dir, "ledger.hecksagon"), memory_hecksagon)
    File.delete(File.join(bluebook_dir, "ledger.world"))
  end

  def check_lineage!(registry, bluebook, text, **extra)
    Hecks::Adapters::PostgresEra::LineageManager.check!(
      registry: registry, bluebook: bluebook, current_text: text, settings: { database: url }, **extra
    )
  end

  def v1_record_state
    { cost: { "cents" => 100, "currency" => "USD" }, kind: { "label" => "biz" }, legacy_note: { "text" => "keep?" } }
  end

  def save_v1_record(bluebook)
    aggregate = bluebook.aggregate("Acct")
    adapter = Hecks::Adapters::PostgresEra.new(aggregate: aggregate, settings: { database: url, domain: "Ledger" })
    adapter.save(Hecks::Runtime::Instance.new(aggregate: aggregate, id: "a1", state: v1_record_state))
  end

  # Holds era 1 from `JS_V1`, as a first boot of the old checkout does, and saves one record.
  def hold_v1_with_a_record
    registry = load_registry(JS_V1)
    bluebook = registry.bluebooks.values.first
    check_lineage!(registry, bluebook, JS_V1)
    save_v1_record(bluebook)
    registry
  end

  def sql(statement, *params)
    db = PG.connect(dbname: JS_DB)
    db.exec_params(statement, params).to_a
  ensure
    db&.close
  end

  def request(operation, **fields)
    { operation: { value: operation }, domain: { value: @domain }, status: "admitted" }.merge(fields)
  end

  def facts(operation, **fields)
    store.examine(**request(operation, **fields)).transform_values { |fact| fact[:value] }
  end

  # The domain as the host loads it from disk, edges and committed approvals included.
  def load_domain_registry
    registry = Hecks::Runtime::Registry.new
    loading = Hecks::Ports::Loading.bootstrap
    Hecks.with_registry(registry) do
      loading.load_library
      loading.load_domain(bluebook_dir)
    end
    registry
  end

  # Boots the current shape the way the host does, edges and committed approvals from disk.
  def mint_v2
    registry = load_domain_registry
    check_lineage!(registry, registry.bluebooks.values.first, JS_V2, directory: bluebook_dir)
    registry
  end

  def apply_report(operation, **fields) = store.apply(**request(operation, **fields)).dig(:report, :value)

  describe "reading" do
    before { write_domain }

    it "answers that no era is held and changes nothing, however often it is asked", :aggregate_failures do
      expect(store.scaffold_translation(domain: { value: @domain }).fetch(:text)).to include("holds no era yet")
      expect(store.audit_translation(domain: { value: @domain }).fetch(:text)).to include("hecks hold_first")
      expect(sql("SELECT to_regclass('hecks_eras') AS present").first["present"]).to be_nil
    end

    it "reports it capable of holding era 1 while none is held" do
      expect(facts("hold_first")).to include(capable: true, held: 0)
    end

    it "holds era 1 when HoldFirst is applied" do
      expect(apply_report("hold_first")).to eq("Ledger holds era 1 now.")
    end

    context "when HoldFirst was applied" do
      before { apply_report("hold_first") }

      it "holds the unchanged text as era 1" do
        expect(sql("SELECT ordinal, held_text FROM hecks_eras WHERE domain = 'Ledger'"))
          .to eq([{ "ordinal" => "1", "held_text" => JS_V2 }])
      end

      it "reports one era held" do
        expect(facts("hold_first")).to include(held: 1)
      end

      it "refuses to hold era 1 twice" do
        expect { store.apply(**request("hold_first")) }.to raise_error(Hecks::Runtime::WiringError, /already holds an era/)
      end
    end
  end

  describe "scaffolding and auditing the edge from era 1" do
    before { hold_v1_with_a_record }

    context "when scaffolding with no edge written" do
      let(:text) { store.scaffold_translation(domain: { value: @domain }).fetch(:text) }

      before do
        write_domain
        text
      end

      it "scaffolds the file name" do
        expect(text).to include("# Save as translations/2-#{label_of(JS_V2)}.bluebook.")
      end

      it "scaffolds the edge as text" do
        expect(text).to include("Hecks.data_translation \"Ledger\", from: #{label_of(JS_V1).inspect}")
      end

      it "writes no file" do
        expect(Dir[File.join(bluebook_dir, "translations", "*")]).to be_empty
      end

      it "leaves era 1 unnamed" do
        expect(sql("SELECT hash FROM hecks_eras WHERE ordinal = 1").first["hash"]).to be_nil
      end
    end

    context "when auditing a pending edge" do
      let(:report) { store.audit_translation(domain: { value: @domain }).fetch(:text) }

      before do
        write_domain(edge: JS_EDGE)
        report
      end

      it "names the edge and the records it covers" do
        expect(report).to include("Ledger::Account (edge #{label_of(JS_V1)} → #{label_of(JS_V2)}, 1 record)")
      end

      it "passes, asking for review of the samples" do
        expect(report).to include("AUDIT PASSED — review the samples above")
      end

      it "leaves era 1 unnamed" do
        expect(sql("SELECT hash FROM hecks_eras WHERE ordinal = 1").first["hash"]).to be_nil
      end
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

    def approval_path = File.join(bluebook_dir, "translations", "#{label_of(JS_V1)}-#{label_of(JS_V2)}.approval")

    def approval_document = JSON.parse(File.read(approval_path))

    def passing_rehearsal(**overrides)
      { snapshot: { value: "rds:ledger-2026-09-28" }, host_version: { value: Hecks::VERSION },
        rehearsal: { value: "pass" }, rehearsed_at: { value: "2026-09-28T12:00:00Z" } }.merge(overrides)
    end

    context "with an edge that has no compute or rekey" do
      before { write_domain(edge: JS_EDGE) }

      it "reports the facts such an edge needs" do
        expect(facts("approve_translation")).to include(capable: true, edges: 1, audited: true, rehearsal_needed: false)
      end

      it "writes the file, and reports its path" do
        expect(apply_report("approve_translation")).to include(approval_path)
      end
    end

    context "with an edge that has no compute or rekey, once approved" do
      before do
        write_domain(edge: JS_EDGE)
        apply_report("approve_translation")
      end

      it "writes the edge, its digest, who approved and when, in that order" do
        expect(approval_document.keys).to eq(%w[edge edge_digest approved_by approved_at])
      end

      it "names the edge and its approver" do
        expect(approval_document).to include("edge"        => "#{label_of(JS_V1)}-#{label_of(JS_V2)}",
                                             "approved_by" => "Ada Lovelace <ada@example.com>")
      end

      it "stamps the time of approval" do
        expect(approval_document["approved_at"]).to match(/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T/)
      end
    end

    context "with an edge that has a compute or rekey" do
      before { write_domain(edge: JS_COMPUTED_EDGE) }

      it "asks a rehearsal of it" do
        expect(facts("approve_translation")).to include(rehearsal_needed: true, rehearsal_recorded: false)
      end

      it "refuses to apply it without a rehearsal that passed" do
        expect { store.apply(**request("approve_translation")) }
          .to raise_error(ArgumentError, /approved on a rehearsal that passed/)
      end

      it "records a rehearsal that passed" do
        expect(facts("approve_translation", **passing_rehearsal)).to include(rehearsal_recorded: true)
      end

      it "does not record a rehearsal that failed" do
        expect(facts("approve_translation", **passing_rehearsal(rehearsal: { value: "fail" })))
          .to include(rehearsal_recorded: false)
      end

      it "applies the committed file at the mint", :aggregate_failures do
        store.apply(**request("approve_translation", **passing_rehearsal))

        expect(mint_v2.resolved_eras["Ledger"]).to eq(2)
        expect(sql("SELECT edge_digest FROM hecks_approvals").size).to eq(1)
      end

      it "records the release it ran on when the rehearsal names no host version", :aggregate_failures do
        store.apply(**request("approve_translation", **passing_rehearsal.except(:host_version)))

        expect(approval_document.dig("rehearsal", "host_version")).to eq(Hecks::VERSION)
        expect { mint_v2 }.not_to raise_error
      end

      it "does not mint on a committed approval whose edge changed since" do
        store.apply(**request("approve_translation", **passing_rehearsal))
        edge_path = File.join(bluebook_dir, "translations", "2-#{label_of(JS_V2)}.bluebook")
        File.write(edge_path, File.read(edge_path).sub("upper(", "lower("))

        expect { mint_v2 }.to raise_error(Hecks::Runtime::WiringError, /human-approved sample is its only verification/)
      end
    end
  end

  describe "re-attesting a held text" do
    before do
      hold_v1_with_a_record
      write_domain
    end

    let(:edited) { "# a comment added by hand\n#{JS_V1}" }

    def attestation_text = store.attestation(domain: { value: @domain }, era: { value: 1 }).fetch(:text)

    context "with the held text edited by hand" do
      before { sql("UPDATE hecks_eras SET held_text = $1 WHERE ordinal = 1", edited) }

      it "reads the text back, saying it does not match its digest" do
        expect(attestation_text).to include("does NOT match its recorded digest", "# a comment added by hand",
                                            "shape:    unchanged")
      end

      it "reports it drifted, loadable, with its shape kept" do
        expect(facts("reattest", era: { value: 1 })).to include(capable: true, drifted: true, loadable: true, shape_kept: true)
      end
    end

    context "with the edited text admitted" do
      before do
        sql("UPDATE hecks_eras SET held_text = $1 WHERE ordinal = 1", edited)
        @report = apply_report("reattest", era: { value: 1 })
      end

      it "attests to it" do
        expect(@report).to start_with("ATTESTED: era 1 re-frozen as ")
      end

      it "records one attestation" do
        expect(sql("SELECT count(*)::int AS n FROM hecks_attestations").first["n"].to_i).to eq(1)
      end

      it "has nothing left to re-attest" do
        expect(attestation_text).to include("nothing to re-attest")
      end

      it "reports no drift" do
        expect(facts("reattest", era: { value: 1 })).to include(drifted: false)
      end
    end

    it "reports an edit that changed the era's shape, for Era.Permit to refuse whatever was confirmed", :aggregate_failures do
      sql("UPDATE hecks_eras SET held_text = $1 WHERE ordinal = 1", JS_V2)

      expect(facts("reattest", era: { value: 1 })).to include(drifted: true, loadable: true, shape_kept: false)
      expect { attestation_text }.to raise_error(Hecks::Runtime::NotFound, /changed the era's SHAPE/)
    end

    it "reports a text that no longer loads as a bluebook" do
      sql("UPDATE hecks_eras SET held_text = $1 WHERE ordinal = 1", "Hecks.bluebook \"Ledger\" do\n  ((((\nend\n")

      expect(facts("reattest", era: { value: 1 })).to include(drifted: true, loadable: false, shape_kept: false)
    end

    it "reports a text that matches its digest as nothing to attest" do
      expect(facts("reattest", era: { value: 1 })).to include(drifted: false)
    end

    it "refuses an era that is not held" do
      expect { facts("reattest", era: { value: 7 }) }.to raise_error(Hecks::Runtime::NotFound, /holds no era 7/)
    end
  end

  describe "backfilling projections" do
    def apply_backfill = apply_report("backfill_projections")

    before do
      write_domain
      hold_v1_with_a_record
      sql("UPDATE hecks_eras SET held_projection = NULL WHERE ordinal = 1")
    end

    it "stores the shape for the eras that predate it" do
      apply_backfill

      expect(sql("SELECT held_projection IS NOT NULL AS held FROM hecks_eras").first["held"]).to eq("t")
    end

    it "says how many eras it backfilled" do
      expect(apply_backfill).to include("backfilled 1 era")
    end

    it "says so when there is nothing to do" do
      apply_backfill

      expect(apply_backfill).to include("nothing to do")
    end
  end

  describe "merging the tail" do
    # An old checkout keeps writing era 1 after era 2 was minted: `a1` in both worlds, `a9` in one.
    def fork_worlds
      hold_v1_with_a_record
      write_domain(edge: JS_EDGE)
      registry = load_domain_registry
      bluebook = registry.bluebooks.values.first
      check_lineage!(registry, bluebook, JS_V2, directory: bluebook_dir)
      save_in_era_two(bluebook.aggregate("Account"))
      old_write("a1", 111)
      old_write("a9", 5)
    end

    def save_in_era_two(account)
      adapter = Hecks::Adapters::PostgresEra.new(aggregate: account, settings: { database: url, domain: "Ledger", era: 2 })
      state = { amount: { "cents" => 999 }, kind: { "label" => "business" }, denomination: { "code" => "USD" }, status: "open" }
      adapter.save(Hecks::Runtime::Instance.new(aggregate: account, id: "a1", state: state))
    end

    def old_write(id, cents)
      state = JSON.generate(cost: { "cents" => cents, "currency" => "USD" }, kind: { "label" => "biz" },
                            legacy_note: { "text" => "late" })
      ordinal = sql("INSERT INTO hecks_journal_ledger (era, aggregate, aggregate_id, operation, state) " \
                    "VALUES (1, 'acct', $1, 'save', $2) RETURNING ordinal", id, state).first["ordinal"]
      sql("INSERT INTO ledger_acct_head_snapshot_1 (id, ordinal, state) VALUES ($1, $2, $3) " \
          "ON CONFLICT (id) DO UPDATE SET ordinal = $2, state = $3", id, ordinal, state)
    end

    context "with both worlds having written" do
      before { fork_worlds }

      it "reports the records both worlds touched that have no winner" do
        expect(facts("merge_tail")).to include(capable: true, held: 2, forks: 0, contested: 1)
      end

      it "reports none contested once each has a winner" do
        expect(facts("merge_tail", winners: { value: "a1:new" })).to include(contested: 0)
      end

      it "keeps the database's own refusal when a winner is missing" do
        expect { store.apply(**request("merge_tail")) }
          .to raise_error(Hecks::Runtime::WiringError, /touched by both worlds since the cut — account#a1/)
      end
    end

    context "with both worlds having written, merged with a winner" do
      before do
        fork_worlds
        @report = apply_report("merge_tail", winners: { value: "a1:new" })
      end

      it "counts the post-cut writes, and names the winner" do
        expect(@report).to include("2 post-cut writes in ancestor eras before the merge", "winner a1=new appended")
      end

      it "makes the winner's state the head" do
        expect(sql("SELECT state FROM ledger_account_head WHERE id = 'a1'").first["state"]).to include('"cents": 999')
      end
    end

    it "finds nothing to merge at era 1" do
      hold_v1_with_a_record
      write_domain(edge: JS_EDGE)

      expect(facts("merge_tail")).to include(capable: true, held: 1)
    end
  end

  describe "through the launcher" do
    def run_verb(*argv)
      @hecks ||= Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false)
      Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")
    end

    def refusal_reason(output) = JSON.parse(output).fetch("refused_reactions").first.fetch("reason")

    def settlement_row(run) = JSON.parse(run_verb("era.settlement", run).first).first

    context "with an edge written" do
      before { write_domain(edge: JS_EDGE) }

      it "holds the first era when confirmed" do
        run_verb("era.hold_first", @domain, "run=first-1", "--confirm")
        row = settlement_row("first-1")

        expect([row.fetch("status"), row.dig("report", "value")]).to eq(["settled", "Ledger holds era 1 now."])
      end

      it "refuses a merge before a second era exists" do
        run_verb("era.hold_first", @domain, "run=first-1", "--confirm")
        out, = run_verb("era.merge_tail", @domain, "run=merge-1", "--confirm")

        expect(refusal_reason(out)).to eq("Permit refused — an era beyond the first stands before a tail is merged")
      end

      it "refuses holding the first era again, saying none is held yet" do
        run_verb("era.hold_first", @domain, "run=first-1", "--confirm")
        run_verb("era.merge_tail", @domain, "run=merge-1", "--confirm")
        again, = run_verb("era.hold_first", @domain, "run=first-2", "--confirm")

        expect(refusal_reason(again)).to eq("Permit refused — no era is held yet")
      end
    end

    context "with era 1 held and the edge written" do
      before do
        write_domain(edge: JS_EDGE)
        hold_v1_with_a_record
      end

      # The reasons the givens refuse a re-attestation of era 1 for, as run `run`.
      def reattest_reasons(run)
        out, = run_verb("era.reattest", @domain, "era=1", "run=#{run}", "--confirm")
        JSON.parse(out).fetch("refused_reactions", []).map { |reaction| reaction.fetch("reason") }
      end

      it "refuses an attestation when the held text still matches its digest" do
        expect(reattest_reasons("att-1"))
          .to eq(["Permit refused — the held text no longer matches its digest: there is nothing to re-attest"])
      end

      it "refuses an attestation when the edit changed the era's shape" do
        sql("UPDATE hecks_eras SET held_text = $1 WHERE ordinal = 1", JS_V2)

        expect(reattest_reasons("att-2"))
          .to eq(["Permit refused — the edit kept the era's shape, not just its text: restore a text with the original shape"])
      end

      it "attests an edited text when the givens admit it", :aggregate_failures do
        sql("UPDATE hecks_eras SET held_text = $1 WHERE ordinal = 1", "# a comment added by hand\n#{JS_V1}")

        expect(reattest_reasons("att-3")).to be_empty
        row = settlement_row("att-3")
        expect([row.fetch("status"), row.dig("report", "value")]).to match(["settled", /\AATTESTED: era 1 re-frozen as /])
      end
    end

    it "words the store-keeps-eras rule for a domain on Memory" do
      make_memory_domain

      out, = run_verb("era.backfill_projections", @domain, "run=backfill-1")

      expect(refusal_reason(out)).to eq("Permit refused — the store keeps eras")
    end
  end

  describe "a domain whose store keeps no eras" do
    it "reports that it is not capable, for the store-keeps-eras rule to refuse", :aggregate_failures do
      make_memory_domain

      expect(facts("hold_first")).to include(capable: false)
      expect { store.scaffold_translation(domain: { value: @domain }) }
        .to raise_error(Hecks::Runtime::NotFound, /Memory, which holds no eras/)
    end
  end
end
