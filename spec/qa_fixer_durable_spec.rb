require "hecks"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require_relative "support/postgres_probe"
require_relative "support/scratch_postgres"
require_relative "support/fenced_owner"

# The Fixer's attempts on a disposable PostgresEra database, booted from a fixture copy of the Fixer
# domain whose world names that database. Each boot runs in its own process, so an attempt written
# by one process is read by a fresh one, which is what the QA event pump depends on. The real ledger
# and its hecks_fixer database are never touched.
RSpec.describe "the Fixer's durable attempts", :io do
  FIXER_DURABLE_DB = "hecks_fixer_durable_spec".freeze
  FIXER_LIB = File.join(InMemoryDomain::ROOT, "lib").freeze
  FIXER_SOURCE = File.join(InMemoryDomain::ROOT, "lib/hecks/fixer").freeze
  FIXER_QA_BLUEBOOK = File.join(InMemoryDomain::ROOT, "qa/bluebook").freeze

  scratch_postgres FIXER_DURABLE_DB, fenced: true

  around do |example|
    @dir = Dir.mktmpdir("fixer_durable")
    write_fixture
    example.run
  ensure
    FileUtils.rm_rf(@dir)
  end

  def write_fixture
    FileUtils.cp(File.join(FIXER_SOURCE, "fixer.bluebook"), File.join(@dir, "fixer.bluebook"))
    File.write(File.join(@dir, "fixer.hecksagon"), fixture_hecksagon)
    File.write(File.join(@dir, "fixer.world"), fixture_world)
  end

  # The Fixer attaches Governance, so the fixture declares the sibling Governance block beside it.
  def fixture_hecksagon
    <<~RUBY
      Hecks.hecksagon "Fixer" do
        attaches "Governance"
        persisted_by "Memory"
        Fixer::Attempt.persisted_by("PostgresEra")
      end

      Hecks.hecksagon "Governance" do
        persisted_by "Memory"
      end
    RUBY
  end

  def fixture_world
    <<~RUBY
      Hecks.world "Fixer" do
        persisted_by("PostgresEra") do
          database "#{FencedOwner.url(FIXER_DURABLE_DB)}"
          mint_eras false
        end
      end
    RUBY
  end

  # Runs one fresh Ruby process that boots the fixture and evaluates the script against it.
  def run_fresh(script)
    out, status = Open3.capture2e({ "FIXER_FIXTURE_DIR" => @dir }, RbConfig.ruby, "-I", FIXER_LIB,
                                  "-e", preamble + script)
    raise "fresh process failed:\n#{out}" unless status.success?

    out.strip
  end

  def preamble
    <<~RUBY
      require "hecks"
      $fixer = Hecks.boot(ENV.fetch("FIXER_FIXTURE_DIR"))
    RUBY
  end

  def fixer_database_eras
    db = PG.connect(dbname: FIXER_DURABLE_DB)
    db.exec("SELECT domain, ordinal FROM hecks_eras ORDER BY domain, ordinal").map(&:values)
  ensure
    db&.close
  end

  it "writes an attempt in one process that a fresh process reads back" do
    run_fresh(%($fixer.dispatch_flat("Fixer::Attempt.Open", reference: "BUG-durable-1")))

    expect(run_fresh(%(puts Fixer::Attempt.find("BUG-durable-1").status))).to eq("logged")
  end

  it "boots the Fixer world without a refusal" do
    expect(run_fresh(%(puts "booted"))).to eq("booted")
  end

  it "gives a fresh Fixer database its own era on first boot" do
    run_fresh(%(puts "booted"))

    expect(fixer_database_eras).to include(%w[Fixer 1])
  end

  it "binds Attempt to PostgresEra in the QA hecksagon and names hecks_fixer in its world", :aggregate_failures do
    hecksagon = File.read(File.join(FIXER_QA_BLUEBOOK, "quality_control.hecksagon"))
    world = File.read(File.join(FIXER_QA_BLUEBOOK, "fixer.world"))

    expect(hecksagon).to include(%(Fixer::Attempt.persisted_by("PostgresEra")))
    expect(world).to include("postgres://hecks_qa@localhost/hecks_fixer")
  end
end
