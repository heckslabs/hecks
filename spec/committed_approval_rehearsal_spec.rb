require "json"
require "open3"
require "securerandom"
require "tempfile"
require "tmpdir"
require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/postgres_probe"

# Rehearses the committed approval end to end on a scratch Postgres: an edge with a compute rule
# boots when `translations/<edge>.approval` carries its digest and a passed rehearsal, and refuses
# when the digest does not match. Ruby's mint runs in process; Rust's runs through mint_harness
# when cargo is installed.
RSpec.describe "Committed approval rehearsal", :io do
  DOMAIN_NAME = "LedgerCompute".freeze
  SCRATCH_PASSWORD = "scratch-only".freeze
  HOST_DIR = File.join(InMemoryDomain::ROOT, "rust", "host")

  BLUEBOOK_V1 = <<~BLUEBOOK.freeze
    Hecks.bluebook "LedgerCompute" do
      aggregate "Account" do
        identified_by :kind
        attribute :score, Score
        attribute :kind, Kind

        value_object "Score" do
          attribute :value, Integer
        end

        value_object "Kind" do
          attribute :label, String
        end
      end
    end
  BLUEBOOK

  BLUEBOOK_V2 = <<~BLUEBOOK.freeze
    Hecks.bluebook "LedgerCompute" do
      aggregate "Account" do
        identified_by :kind
        attribute :doubled, Doubled
        attribute :kind, Kind

        value_object "Doubled" do
          attribute :value, Integer
        end

        value_object "Kind" do
          attribute :label, String
        end
      end
    end
  BLUEBOOK

  REHEARSAL_BLOCK = { "snapshot" => "rds:ledger-2026-09-28", "host_version" => "3.0.0",
                      "result" => "pass", "at" => "2026-09-28T12:00:00Z" }.freeze

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?
  end

  # Loads a bluebook, and optionally a translation edge, into a fresh registry.
  def load_registry(source, translation_source: nil)
    registry = Hecks::Runtime::Registry.new
    file = Tempfile.new(["committed-approval-", ".bluebook"])
    file.write(source)
    file.flush
    Hecks.with_registry(registry) do
      Hecks::Ports::Loading.bootstrap.load_library
      Kernel.eval(source, TOPLEVEL_BINDING, file.path, 1)
      eval(translation_source) if translation_source
    end
    registry
  ensure
    file&.close!
  end

  def label_of(source)
    Hecks::Runtime::StorageShape.mint_hash(load_registry(source).bluebooks.values.first)[0, 6]
  end

  def edge_source(from:, to:)
    <<~RUBY
      Hecks.data_translation("LedgerCompute", from: #{from.inspect}, to: #{to.inspect}) do
        aggregate("Account") do
          compute :score, to: :doubled, sql: "jsonb_build_object('value', (score::jsonb->>'value')::int * 2)"
        end
      end
    RUBY
  end

  def create_scratch!(suffix)
    require "pg"
    @db = "cmt_appr_#{suffix}"
    @owner = "cmt_appr_owner_#{suffix}"
    admin = PG.connect(dbname: "postgres")
    # A password, so TCP works on a server whose pg_hba wants one; libpq and mint_harness both
    # read it from the environment, set around each example.
    admin.exec("CREATE ROLE #{@owner} LOGIN PASSWORD '#{SCRATCH_PASSWORD}'")
    admin.exec("CREATE DATABASE #{@db}")
    admin.close
    conn = PG.connect(dbname: @db)
    conn.exec("GRANT CONNECT ON DATABASE #{@db} TO #{@owner}")
    conn.exec("GRANT USAGE, CREATE ON SCHEMA public TO #{@owner}")
    conn.exec("ALTER DATABASE #{@db} OWNER TO #{@owner}")
    conn.close
  end

  def drop_scratch!
    return unless @db

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{@db} WITH (FORCE)")
    admin.exec("DROP ROLE IF EXISTS #{@owner}")
    admin.close
  end

  def owner_url = "postgres://#{@owner}@localhost/#{@db}"

  def journal_approvals
    conn = PG.connect(host: "localhost", dbname: @db, user: @owner)
    conn.exec_params("SELECT count(*) AS n FROM hecks_approvals WHERE domain = $1", [DOMAIN_NAME]).first["n"].to_i
  ensure
    conn&.close
  end

  def ruby_boot!(source, translation_source: nil, directory: nil)
    registry = load_registry(source, translation_source: translation_source)
    Hecks::Adapters::PostgresEra::LineageManager.check!(
      registry: registry, bluebook: registry.bluebooks.values.first, current_text: source,
      settings: { database: owner_url }, directory: directory
    )
  end

  # Writes the committed file for the rehearsal, with a caller-supplied digest.
  def commit_approval(directory, edge, digest: nil, rehearsal: REHEARSAL_BLOCK)
    document = Hecks::Translation::ApprovalFile.build(
      edge: edge, approved_by: "Ada <ada@example.com>", approved_at: "2026-09-28T12:30:00Z", rehearsal: REHEARSAL_BLOCK
    )
    document["edge_digest"] = digest if digest
    document.delete("rehearsal") unless rehearsal
    document["rehearsal"] = rehearsal if rehearsal && rehearsal != REHEARSAL_BLOCK
    Hecks::Translation::ApprovalFile.write!(directory, edge, document)
  end

  let(:from_label) { label_of(BLUEBOOK_V1) }
  let(:to_label) { label_of(BLUEBOOK_V2) }
  let(:translation_source) { edge_source(from: from_label, to: to_label) }
  let(:edge) do
    load_registry(BLUEBOOK_V2, translation_source: translation_source).translations.find { |t| t.domain == DOMAIN_NAME }
  end
  let(:bad_digest) { "0" * 64 }

  around do |example|
    saved_password = ENV.fetch("PGPASSWORD", nil)
    # The admin connections (create and drop) authenticate as the caller; only the example body
    # runs as the scratch owner.
    create_scratch!(SecureRandom.hex(4))
    ENV["PGPASSWORD"] = SCRATCH_PASSWORD
    Dir.mktmpdir("committed-approval-") { |dir| (@dir = dir) && example.run }
  ensure
    saved_password ? ENV["PGPASSWORD"] = saved_password : ENV.delete("PGPASSWORD")
    drop_scratch!
  end

  describe "Ruby (LineageManager.check!)" do
    before { ruby_boot!(BLUEBOOK_V1) }

    def boot_v2! = ruby_boot!(BLUEBOOK_V2, translation_source: translation_source, directory: @dir)

    it "refuses a compute edge with no approval at all" do
      expect { boot_v2! }.to raise_error(Hecks::Runtime::WiringError, /compute or rekey/)
      expect(journal_approvals).to eq(0)
    end

    it "refuses a committed approval whose digest is not the edge's" do
      commit_approval(@dir, edge, digest: bad_digest)

      expect { boot_v2! }.to raise_error(Hecks::Runtime::WiringError, /compute or rekey/)
      expect(journal_approvals).to eq(0)
    end

    it "refuses a committed approval with no rehearsal that passed" do
      Hecks::Translation::ApprovalFile.write!(
        @dir, edge,
        "edge" => Hecks::Translation::ApprovalFile.edge_name(edge),
        "edge_digest" => Hecks::Translation::Audit.edge_digest(edge),
        "approved_by" => "Ada", "approved_at" => "2026-09-28T12:30:00Z",
        "rehearsal" => REHEARSAL_BLOCK.merge("result" => "fail")
      )

      expect { boot_v2! }.to raise_error(Hecks::Runtime::WiringError, /compute or rekey/)
    end

    it "boots on a committed approval, applies it to the journal, and mints era 2" do
      commit_approval(@dir, edge)

      expect(boot_v2!).to eq(2)
      expect(journal_approvals).to eq(1)
    end

    it "reboots on era 2 once the file is gone, since the journal holds the mint" do
      commit_approval(@dir, edge)
      boot_v2!
      FileUtils.rm_rf(File.join(@dir, "translations"))

      expect { boot_v2! }.not_to raise_error
    end
  end

  describe "Rust (mint_harness)" do
    def cargo? = system("cargo", "--version", out: File::NULL, err: File::NULL)

    def harness
      self.class.instance_variable_get(:@mint_harness) || self.class.instance_variable_set(:@mint_harness, build_harness)
    end

    def build_harness
      _out, err, status = Open3.capture3("cargo", "build", "--bin", "mint_harness", chdir: HOST_DIR)
      raise "cargo build --bin mint_harness failed:\n#{err}" unless status.success?

      File.join(HOST_DIR, "target", "debug", "mint_harness")
    end

    def export_ir(source, translation_source: nil, directory: nil)
      registry = load_registry(source, translation_source: translation_source)
      name = registry.bluebooks.keys.first
      ir = Hecks::Projector::Exporter.call(registry).fetch(name).merge(
        translations: Hecks::Projector::Exporter.translations(registry).select { |e| e[:domain] == name },
        source_text:  source
      )
      approvals = directory ? Hecks::Translation::ApprovalFile.read_all(directory) : []
      ir[:approvals] = approvals unless approvals.empty?
      ir
    end

    def mint(document)
      file = Tempfile.new(["committed-approval-ir-", ".json"])
      file.write(JSON.generate(document))
      file.flush
      Open3.capture3(harness, @db, @owner, DOMAIN_NAME, file.path)
    ensure
      file&.close!
    end

    before do
      skip "cargo is not on the PATH — the Rust half of the rehearsal cannot run" unless cargo?
      _out, err, status = mint(export_ir(BLUEBOOK_V1))
      raise "era 1 mint failed: #{err}" unless status.success?
    end

    def v2_ir = export_ir(BLUEBOOK_V2, translation_source: translation_source, directory: @dir)

    it "refuses a compute edge with no approval" do
      _out, err, status = mint(v2_ir)

      expect(status).not_to be_success
      expect(err).to include("compute or rekey")
    end

    it "refuses a committed approval whose digest is not the edge's" do
      commit_approval(@dir, edge, digest: bad_digest)

      _out, err, status = mint(v2_ir)

      expect(status).not_to be_success
      expect(err).to include("compute or rekey")
      expect(journal_approvals).to eq(0)
    end

    it "mints on a committed approval Ruby wrote and applies it to the journal" do
      commit_approval(@dir, edge)

      out, err, status = mint(v2_ir)

      expect(status).to be_success, err
      expect(JSON.parse(out.lines.last)).to include("era" => 2, "label" => to_label)
      expect(journal_approvals).to eq(1)
    end
  end
end
