require "spec_helper"
require_relative "../../support/rehearsal_shop"
require "fileutils"
require "json"
require "open3"
require "securerandom"
require "tmpdir"
require "pg"
require "digest"
require_relative "../../support/fenced_owner"
require_relative "../../support/rehearsal_source_database"
require_relative "../../../lib/hecks/hecks/adapters/rehearsal_store"

# The RehearsalStore port's adapter against what it reaches outside the process: a real local
# Postgres, whose server the shop's world names by an environment variable, and the Rust host's
# mint audit as the second engine. Needs a reachable Postgres and a Rust toolchain.
RSpec.describe Hecks::Adapters::RehearsalStore, :io do
  let(:root) { Dir.mktmpdir("hecks-rehearsal-store") }
  let(:shop) { File.join(root, "shop") }
  let(:run) { "rehearsal-#{SecureRandom.hex(4)}" }
  let(:source) { "hecks_rehearsal_spec_source_#{SecureRandom.hex(4)}" }

  def server_variable = "HECKS_REHEARSAL_SPEC_SERVER"

  before { RehearsalShop.copy_to(shop) }

  after do
    ENV.delete(server_variable)
    ENV.delete("HECKS_VALIDATE_HARNESS")
    FileUtils.remove_entry(root)
  end

  def held(run) = { domain: { value: shop }, run: { value: run } }

  def survey(run) = described_class.new.survey(**held(run))

  def examine(run) = described_class.new.examine(**held(run))

  def rehearsed_by(block)
    world = File.join(shop, "bluebook", "shop.world")
    File.write(world, File.read(world).sub(/  rehearsed_by.*?\n  end\n/m, "  #{block}\n"))
  end

  def stored_row(id, **state)
    document = JSON.parse(File.read(File.join(shop, "rehearsal", "rows.json")))
    document["records"]["Widget"][id] = { "sku" => { "value" => id }, "status" => "listed" }.merge(state)
    File.write(File.join(shop, "rehearsal", "rows.json"), JSON.generate(document))
  end

  def build_harness
    host = File.join(InMemoryDomain::ROOT, "rust/host")
    _out, err, status = Open3.capture3("cargo", "build", "--bin", "validate_harness", chdir: host)
    raise "cargo build --bin validate_harness failed:\n#{err}" unless status.success?

    File.join(host, "target", "debug", "validate_harness")
  end

  describe "the Rust host's audit as the second engine" do
    before { ENV["HECKS_VALIDATE_HARNESS"] = build_harness }

    it "refuses a stored value the closed set does not admit, which the Ruby audit lets through", :aggregate_failures do
      stored_row("w3", "size" => { "value" => "huge" })
      survey("closed-set")
      facts = examine("closed-set")

      expect(facts[:refused_rows].map { |row| row[:id] }).to eq(["w3"])
      expect(facts[:parity]).to include(engine: "rust", status: "differ")
    end

    it "agrees with the Ruby audit when nothing stored is refused" do
      survey("clean")

      expect(examine("clean")[:parity]).to include(status: "agree")
    end
  end

  def dump = File.join(root, "previous.dump")

  # The shop's `rehearsed_by` block for a dump the server holds, with any further settings.
  def postgres_block(*extra)
    lines = ["connection_env \"#{server_variable}\"", "mode \"dump\"", "dump \"../../previous.dump\"", *extra]
    "rehearsed_by(\"Postgres\") do\n#{lines.map { |line| "    #{line}\n" }.join}  end"
  end

  def rehearsal_databases
    admin = PG.connect(dbname: "postgres")
    admin.exec("SELECT datname FROM pg_database WHERE datname LIKE 'hecks_rehearsal_%'").map { |row| row["datname"] }
  ensure
    admin&.close
  end

  describe "a postgres copy named by an environment variable" do
    before do
      ENV[server_variable] = "postgres:///postgres"
      make_source_database
      rehearsed_by(postgres_block)
    end

    after { RehearsalSourceDatabase.drop(source) }

    def make_source_database
      RehearsalSourceDatabase.build(shop: shop, source: source, dump: dump)
    end

    it "restores the dump, reads the era it holds, and finds an edge leads to the shape", :aggregate_failures do
      facts = survey(run)
      examine(run)

      expect(facts[:store]).to eq(value: "postgres")
      expect(facts[:before]).to eq(value: "708420")
      expect(facts[:minting]).to eq(value: "next")
    end

    it "audits the stored rows through the edge, and drops the copy it made", :aggregate_failures do
      survey(run)
      facts = examine(run)

      expect(facts[:edge_present]).to eq(value: true)
      expect(facts[:refusal_total]).to eq(value: 0)
      expect(facts[:released]).to eq(value: true)
    end

    it "leaves no rehearsal database behind" do
      survey(run)
      examine(run)

      expect(rehearsal_databases.select { |name| name.end_with?(Digest::SHA256.hexdigest(run)[0, 16]) }).to be_empty
    end

    it "refuses a server the environment does not name", :aggregate_failures do
      ENV.delete(server_variable)

      expect { survey(run) }.to raise_error(Hecks::Adapters::Rehearsal::Refused, /#{server_variable} is not set/)
    end
  end

  describe "a dump whose lineage is held in a schema of its own" do
    before do
      ENV[server_variable] = "postgres:///postgres"
      RehearsalSourceDatabase.build(shop: shop, source: source, dump: dump, schema: "shop_data")
      declare_schema
    end

    after { RehearsalSourceDatabase.drop(source) }

    def declare_schema(*lines) = rehearsed_by(postgres_block(*lines))

    def surveyed = survey(run)

    it "counts the rows it audited when the world names the schema", :aggregate_failures do
      declare_schema('schema "shop_data"')
      surveyed
      facts = examine(run)

      expect(facts[:audited]).to eq(value: true)
      expect(facts.values_at(:rows_examined, :aggregates_examined)).to eq([{ value: 1 }, { value: 1 }])
    end

    it "reports the schema it read and where that was decided", :aggregate_failures do
      declare_schema('schema "shop_data"')
      facts = surveyed

      expect(facts[:schema_used]).to eq(name: "shop_data", source: "world", matches: :present)
      expect(facts.values_at(:eras_held, :copy_empty)).to eq([{ value: 1 }, { value: false }])
    end

    it "names the environment it loaded", :aggregate_failures do
      declare_schema('schema "shop_data"', 'environment "staging"')
      FileUtils.mkdir_p(File.join(shop, "bluebook", "environments"))
      File.write(File.join(shop, "bluebook", "environments", "staging.hecksagon"), "Hecks.hecksagon \"Shop\" do\nend\n")

      expect(surveyed[:environment_loaded]).to include(name: "staging", source: "world")
    end

    it "ends as an empty copy when the schema is not declared and the lineage is held elsewhere", :aggregate_failures do
      facts = surveyed

      expect(facts[:copy_empty]).to eq(value: true)
      expect(facts[:copy_note][:value]).to include("no era and no rows", "schemas in this copy that hold a lineage: shop_data")
    end

    it "says the schema is not in the copy when the world names one it lacks", :aggregate_failures do
      declare_schema('schema "elsewhere"')
      facts = surveyed

      expect(facts[:schema_used]).to eq(name: "elsewhere", source: "world", present: false)
      expect(facts[:copy_note][:value]).to include("in schema elsewhere (not in the copy)")
    end

    it "creates no schema in a copy it only reads", :aggregate_failures do
      ENV[server_variable] = "postgres:///#{source}"
      rehearsed_by(readonly_block('schema "elsewhere"'))

      expect(surveyed[:schema_used]).to include(name: "elsewhere", present: false)
      expect(schemas_of(source)).not_to include("elsewhere")
    end

    def readonly_block(*lines)
      body = ["connection_env \"#{server_variable}\"", 'mode "readonly_copy"', *lines]
      "rehearsed_by(\"Postgres\") do\n#{body.map { |line| "    #{line}\n" }.join}  end"
    end

    it "drops the copy it made when it answers an empty one", :aggregate_failures do
      facts = surveyed

      expect(facts[:released]).to eq(value: true)
      expect(rehearsal_databases.select { |name| name.end_with?(Digest::SHA256.hexdigest(run)[0, 16]) }).to be_empty
    end

    def schemas_of(database)
      db = PG.connect(dbname: database)
      db.exec("SELECT schema_name FROM information_schema.schemata").map { |row| row["schema_name"] }
    ensure
      db&.close
    end
  end
end
