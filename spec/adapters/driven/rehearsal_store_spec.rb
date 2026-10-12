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
require_relative "../../../lib/hecks/hecks/adapters/rehearsal_store"

# The RehearsalStore port's adapter against what it reaches outside the process: a real local
# Postgres, whose server the shop's world names by an environment variable, and the Rust host's
# mint audit as the second engine. Needs a reachable Postgres and a Rust toolchain.
RSpec.describe Hecks::Adapters::RehearsalStore, :io do
  let(:root) { Dir.mktmpdir("hecks-rehearsal-store") }
  let(:shop) { File.join(root, "shop") }
  let(:run) { "rehearsal-#{SecureRandom.hex(4)}" }

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

  describe "a postgres copy named by an environment variable" do
    let(:source) { "hecks_rehearsal_spec_source_#{SecureRandom.hex(4)}" }

    def dump = File.join(root, "previous.dump")

    before do
      ENV[server_variable] = "postgres:///postgres"
      make_source_database
      rehearsed_by(postgres_block)
    end

    after do
      admin = PG.connect(dbname: "postgres")
      admin.exec("DROP DATABASE IF EXISTS #{source} WITH (FORCE)")
      admin.close
    end

    def postgres_block
      <<~WORLD.chomp.sub(/\A/, "")
        rehearsed_by("Postgres") do
            connection_env "#{server_variable}"
            mode "dump"
            dump "../../previous.dump"
          end
      WORLD
    end

    # The shop as its previous release held it: era 1 minted, one widget stored, dumped to a file.
    def make_source_database
      admin = PG.connect(dbname: "postgres")
      admin.exec("DROP DATABASE IF EXISTS #{source} WITH (FORCE)")
      admin.exec("CREATE DATABASE #{source}")
      admin.close
      FencedOwner.own!(source)
      hold_previous_era
      _out, err, status = Open3.capture3("pg_dump", "--format=custom", "--file", dump, "--dbname", source)
      raise "pg_dump failed: #{err}" unless status.success?
    end

    def hold_previous_era
      text = File.read(File.join(shop, "rehearsal", "previous.bluebook"))
      registry = load_previous(text)
      bluebook = registry.bluebooks.values.first
      settings = { database: FencedOwner.url(source), domain: "Shop" }
      Hecks::Adapters::PostgresEra::LineageManager.check!(registry: registry, bluebook: bluebook, current_text: text,
                                                          settings: settings)
      adapter = Hecks::Adapters::PostgresEra.new(aggregate: bluebook.aggregate("Widget"), settings: settings)
      adapter.save(Hecks::Runtime::Instance.new(aggregate: bluebook.aggregate("Widget"), id: "w1",
                                                state: { sku: { "value" => "w1" }, size: { "value" => "small" } }))
    end

    def load_previous(text)
      registry = Hecks::Runtime::Registry.new
      loading = Hecks::Ports::Loading.bootstrap
      Hecks.with_registry(registry) do
        loading.load_library
        Kernel.eval(text, TOPLEVEL_BINDING, "previous.bluebook", 1)
      end
      registry
    end

    def rehearsal_databases
      admin = PG.connect(dbname: "postgres")
      admin.exec("SELECT datname FROM pg_database WHERE datname LIKE 'hecks_rehearsal_%'").map { |row| row["datname"] }
    ensure
      admin&.close
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
end
